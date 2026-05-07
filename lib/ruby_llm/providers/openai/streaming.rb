# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Streaming methods of the OpenAI API integration
      #
      # OpenAI 流式响应解析：
      # - SSE `data:` 行解析后得到 `data` hash
      # - 取 `choices[0].delta` 作为本次增量
      # - 工具调用 arguments 是字符串片段（`parse_arguments: false`），
      #   由 {StreamAccumulator} 累积后整体 JSON.parse
      # - 错误响应 `parse_streaming_error` 把 OpenAI 错误类型映射到
      #   类似 HTTP 状态码语义
      module Streaming
        module_function

        # 流式端点与同步端点相同（仅请求体里 `stream: true`）。
        def stream_url
          completion_url
        end

        # 把单个 SSE data hash 构造成 {Chunk}。
        # 注意 arguments 不在此层解析（流式中是片段），由累加器统一处理。
        def build_chunk(data)
          usage = data['usage'] || {}
          delta = data.dig('choices', 0, 'delta') || {}
          content_source = delta['content'] || data.dig('choices', 0, 'message', 'content')
          content, thinking_from_blocks = OpenAI::Chat.extract_content_and_thinking(content_source)

          Chunk.new(
            role: :assistant,
            model_id: data['model'],
            content: content,
            thinking: Thinking.build(
              text: thinking_from_blocks || delta['reasoning_content'] || delta['reasoning'],
              signature: delta['reasoning_signature']
            ),
            tool_calls: parse_tool_calls(delta['tool_calls'], parse_arguments: false),
            input_tokens: OpenAI::Chat.input_tokens(usage),
            output_tokens: OpenAI::Chat.output_tokens(usage),
            cached_tokens: OpenAI::Chat.cache_read_tokens(usage),
            cache_creation_tokens: OpenAI::Chat.cache_write_tokens(usage),
            thinking_tokens: OpenAI::Chat.thinking_tokens(usage)
          )
        end

        def parse_streaming_error(data)
          error_data = JSON.parse(data)
          return unless error_data['error']

          case error_data.dig('error', 'type')
          when 'server_error'
            [500, error_data['error']['message']]
          when 'rate_limit_exceeded', 'insufficient_quota'
            [429, error_data['error']['message']]
          else
            [400, error_data['error']['message']]
          end
        end
      end
    end
  end
end
