# frozen_string_literal: true

module RubyLLM
  # Handles streaming responses from AI providers.
  #
  # 流式响应的通用处理逻辑（被 {Provider} include）。
  #
  # 该模块封装：
  # 1. **请求驱动**：用 Faraday 的 `on_data` 钩子分块接收响应字节，
  #    把字节流喂给 `event_stream_parser` 解析 SSE 协议。
  # 2. **chunk 派发**：每解析出一个 JSON `data:` 事件，调用子类提供的
  #    `build_chunk(hash)` 得到 `Chunk` 对象，再交给用户回调与
  #    {StreamAccumulator}。
  # 3. **错误处理**：识别 `event: error` SSE 事件、非 200 响应、JSON
  #    错误体、`{"error": ...}` 嵌入，统一交给 {ErrorMiddleware}。
  # 4. **Faraday 1/2 双兼容**：v1 用 `req.options[:on_data]`，v2 用
  #    `req.options.on_data` 且回调签名不同（额外的 env 参数）。
  #
  # 子类（各 provider 的 `Streaming` mixin）需要实现：
  #   - `stream_url` —— 流式端点 URL
  #   - `build_chunk(data)` —— 将 SSE 事件 hash 构造成 {Chunk}
  module Streaming
    module_function

    # 以流式方式发起补全请求。
    #
    # @param connection [RubyLLM::Connection]
    # @param payload [Hash] 请求体（必须已设置 stream=true 等字段）
    # @param additional_headers [Hash] 额外 HTTP 头
    # @yield [chunk] 用户回调，每个解析出的 chunk 触发一次
    # @return [RubyLLM::Message] 由 StreamAccumulator 拼装出的最终消息
    def stream_response(connection, payload, additional_headers = {}, &block)
      accumulator = StreamAccumulator.new

      response = connection.post stream_url, payload do |req|
        req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
        if faraday_1?
          req.options[:on_data] = handle_stream do |chunk|
            accumulator.add chunk
            block.call chunk
          end
        else
          req.options.on_data = handle_stream do |chunk|
            accumulator.add chunk
            block.call chunk
          end
        end
      end

      message = accumulator.to_message(response)
      RubyLLM.logger.debug { "Stream completed: #{message.content}" }
      message
    end

    # 包装一个 chunk 处理函数，使其只对 hash 形态的解析结果生效。
    # 子类的 `build_chunk` 把 hash 转为 {Chunk} 后交给回调。
    def handle_stream(&block)
      build_on_data_handler do |data|
        block.call(build_chunk(data)) if data.is_a?(Hash)
      end
    end

    private

    def faraday_1?
      Faraday::VERSION.start_with?('1')
    end

    # 构造一个 Faraday `on_data` 处理器：
    # 把字节流送入 `EventStreamParser`，每解析出一个 SSE 事件就交给
    # `handler` 进一步处理。
    def build_on_data_handler(&handler)
      buffer = +''
      parser = EventStreamParser::Parser.new

      FaradayHandlers.build(
        faraday_v1: faraday_1?,
        on_chunk: ->(chunk, env) { process_stream_chunk(chunk, parser, env, &handler) },
        on_failed_response: ->(chunk, env) { handle_failed_response(chunk, buffer, env) }
      )
    end

    # 单个原始字节块的入口分发：
    # 优先识别错误格式（SSE error 事件 / JSON 错误体），其余走正常 SSE 解析。
    def process_stream_chunk(chunk, parser, env, &)
      RubyLLM.logger.debug { "Received chunk: #{chunk}" } if RubyLLM.config.log_stream_debug

      if error_chunk?(chunk)
        handle_error_chunk(chunk, env)
      elsif json_error_payload?(chunk)
        handle_json_error_chunk(chunk, env)
      else
        yield handle_sse(chunk, parser, env, &)
      end
    end

    # 是否是 SSE 风格的错误事件（开头为 `event: error`）。
    def error_chunk?(chunk)
      chunk.start_with?('event: error')
    end

    # 是否是裸 JSON 错误体（部分 provider 在错误时不发 SSE）。
    def json_error_payload?(chunk)
      chunk.lstrip.start_with?('{') && chunk.include?('"error"')
    end

    def handle_json_error_chunk(chunk, env)
      parse_error_from_json(chunk, env, 'Failed to parse JSON error chunk')
    end

    def handle_error_chunk(chunk, env)
      error_data = chunk.split("\n")[1].delete_prefix('data: ')
      parse_error_from_json(error_data, env, 'Failed to parse error chunk')
    end

    def handle_failed_response(chunk, buffer, env)
      buffer << chunk
      error_data = JSON.parse(buffer)
      handle_parsed_error(error_data, env)
    rescue JSON::ParserError
      RubyLLM.logger.debug { "Accumulating error chunk: #{chunk}" }
    end

    def handle_sse(chunk, parser, env, &block)
      parser.feed(chunk) do |type, data|
        case type.to_sym
        when :error
          handle_error_event(data, env)
        else
          yield handle_data(data, env, &block) unless data == '[DONE]'
        end
      end
    end

    def handle_data(data, env)
      parsed = JSON.parse(data)
      return parsed unless parsed.is_a?(Hash) && parsed.key?('error')

      handle_parsed_error(parsed, env)
    rescue JSON::ParserError => e
      RubyLLM.logger.debug { "Failed to parse data chunk: #{e.message}" }
    end

    def handle_error_event(data, env)
      parse_error_from_json(data, env, 'Failed to parse error event')
    end

    def parse_streaming_error(data)
      error_data = JSON.parse(data)
      [500, error_data['message'] || 'Unknown streaming error']
    rescue JSON::ParserError => e
      RubyLLM.logger.debug { "Failed to parse streaming error: #{e.message}" }
      [500, "Failed to parse error: #{data}"]
    end

    def handle_parsed_error(parsed_data, env)
      status, _message = parse_streaming_error(parsed_data.to_json)
      error_response = build_stream_error_response(parsed_data, env, status)
      ErrorMiddleware.parse_error(provider: self, response: error_response)
    end

    def parse_error_from_json(data, env, error_message)
      parsed_data = JSON.parse(data)
      handle_parsed_error(parsed_data, env)
    rescue JSON::ParserError => e
      RubyLLM.logger.debug { "#{error_message}: #{e.message}" }
    end

    def build_stream_error_response(parsed_data, env, status)
      error_status = status || env&.status || 500

      if faraday_1?
        Struct.new(:body, :status).new(parsed_data, error_status)
      else
        env.merge(body: parsed_data, status: error_status)
      end
    end

    # Builds Faraday on_data handlers for different major versions.
    #
    # 针对 Faraday v1 与 v2 的 `on_data` 回调签名差异提供适配：
    #   - v1: `proc { |chunk, size| ... }`
    #   - v2: `proc { |chunk, bytes, env| ... }`
    # v2 在 env 可见状态码非 200 时把 chunk 视为错误体处理。
    module FaradayHandlers
      module_function

      # @param faraday_v1 [Boolean]
      # @param on_chunk [Proc] 正常状态下的字节块处理器
      # @param on_failed_response [Proc] 失败响应字节块处理器
      # @return [Proc]
      def build(faraday_v1:, on_chunk:, on_failed_response:)
        if faraday_v1
          v1_on_data(on_chunk)
        else
          v2_on_data(on_chunk, on_failed_response)
        end
      end

      def v1_on_data(on_chunk)
        proc do |chunk, _size|
          on_chunk.call(chunk, nil)
        end
      end

      def v2_on_data(on_chunk, on_failed_response)
        proc do |chunk, _bytes, env|
          if env&.status == 200
            on_chunk.call(chunk, env)
          else
            on_failed_response.call(chunk, env)
          end
        end
      end
    end
  end
end
