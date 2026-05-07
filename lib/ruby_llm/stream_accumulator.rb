# frozen_string_literal: true

module RubyLLM
  # Assembles streaming responses from LLMs into complete messages.
  #
  # 流式响应累加器 —— 把 SSE 增量 chunk 拼装成一条完整的 {Message}。
  #
  # `Streaming.stream_response` 会创建一个 `StreamAccumulator`，对每个
  # 收到的 `Chunk` 调用 {#add}，所有 chunk 处理完毕后调用 {#to_message}
  # 得到最终 assistant 消息。
  #
  # 累加器需要处理的"碎片化"问题：
  #
  # 1. **文本内容**：直接拼接到 `@content`。
  # 2. **`<think>...</think>` 标签**：部分 provider 的"伪思考"格式
  #    会把推理混在正文里；累加器维护一个状态机，把标签内文本提取到
  #    `@thinking_text`，避免污染正文。注意标签可能跨 chunk 切割，
  #    需要 `@pending_think_tag` 缓冲未完整的标签前缀。
  # 3. **结构化 thinking**（Anthropic 等）：直接来自 `chunk.thinking`，
  #    包含 `text` 与 `signature`。
  # 4. **工具调用**：流式工具调用通常先发一个带 id+name 的 chunk，
  #    后续 chunk 仅追加 arguments JSON 字符串片段；累加器以 id 索引
  #    并把片段拼到对应 ToolCall 的 arguments 上。最后 {#tool_calls_from_stream}
  #    把 arguments 字符串 `JSON.parse` 为 Hash。
  # 5. **token 计数**：取最后一个 chunk 的非空数值（多家 provider 在
  #    最后一个 chunk 才发 usage）。
  class StreamAccumulator
    # @!attribute [r] content
    #   @return [String] 已累积的正文文本
    # @!attribute [r] model_id
    #   @return [String, nil] 来自首个 chunk 的模型 ID
    # @!attribute [r] tool_calls
    #   @return [Hash{String => RubyLLM::ToolCall}] 工具调用映射
    attr_reader :content, :model_id, :tool_calls

    def initialize
      @content = +''
      @thinking_text = +''
      @thinking_signature = nil
      @tool_calls = {}
      @input_tokens = nil
      @output_tokens = nil
      @cached_tokens = nil
      @cache_creation_tokens = nil
      @thinking_tokens = nil
      @inside_think_tag = false
      @pending_think_tag = +''
      @latest_tool_call_id = nil
    end

    # 接收一个流式 chunk 并合并入累加器状态。
    #
    # @param chunk [RubyLLM::Chunk]
    # @return [void]
    def add(chunk)
      RubyLLM.logger.debug { chunk.inspect } if RubyLLM.config.log_stream_debug
      @model_id ||= chunk.model_id

      handle_chunk_content(chunk)
      append_thinking_from_chunk(chunk)
      count_tokens chunk
      RubyLLM.logger.debug { inspect } if RubyLLM.config.log_stream_debug
    end

    # 将累加结果转换为完整的 assistant {Message}。
    #
    # @param response [Faraday::Response] 整体 HTTP 响应（用于 `raw` 字段）
    # @return [RubyLLM::Message]
    def to_message(response)
      Message.new(
        role: :assistant,
        content: content.empty? ? nil : content,
        thinking: Thinking.build(
          text: @thinking_text.empty? ? nil : @thinking_text,
          signature: @thinking_signature
        ),
        tokens: Tokens.build(
          input: @input_tokens,
          output: @output_tokens,
          cached: @cached_tokens,
          cache_creation: @cache_creation_tokens,
          thinking: @thinking_tokens
        ),
        model_id: model_id,
        tool_calls: tool_calls_from_stream,
        raw: response
      )
    end

    private

    # 把累积的工具调用（arguments 仍是字符串片段拼接）转成最终对象 ——
    # arguments 解析为 Hash。空字符串被解释为 `{}`（兼容某些 provider
    # 在没有参数的工具调用上不发 arguments 的场景）。
    def tool_calls_from_stream
      tool_calls.transform_values do |tc|
        arguments = if tc.arguments.is_a?(String) && !tc.arguments.empty?
                      JSON.parse(tc.arguments)
                    elsif tc.arguments.is_a?(String)
                      {}
                    else
                      tc.arguments
                    end

        ToolCall.new(
          id: tc.id,
          name: tc.name,
          arguments: arguments,
          thought_signature: tc.thought_signature
        )
      end
    end

    # 累加流式工具调用。
    #
    # 协议：
    #   - 带 `id` 的 chunk = 工具调用的开端（包含 name，arguments 可空）
    #   - 不带 `id` 的 chunk = 上一个工具调用 arguments 的下一段字符串
    def accumulate_tool_calls(new_tool_calls) # rubocop:disable Metrics/PerceivedComplexity
      RubyLLM.logger.debug { "Accumulating tool calls: #{new_tool_calls}" } if RubyLLM.config.log_stream_debug
      new_tool_calls.each_value do |tool_call|
        if tool_call.id
          tool_call_id = tool_call.id.empty? ? SecureRandom.uuid : tool_call.id
          tool_call_arguments = tool_call.arguments
          if tool_call_arguments.nil? || (tool_call_arguments.respond_to?(:empty?) && tool_call_arguments.empty?)
            tool_call_arguments = +''
          end
          @tool_calls[tool_call.id] = ToolCall.new(
            id: tool_call_id,
            name: tool_call.name,
            arguments: tool_call_arguments,
            thought_signature: tool_call.thought_signature
          )
          @latest_tool_call_id = tool_call.id
        else
          existing = @tool_calls[@latest_tool_call_id]
          if existing
            fragment = tool_call.arguments
            fragment = '' if fragment.nil?
            existing.arguments << fragment
            if tool_call.thought_signature && existing.thought_signature.nil?
              existing.thought_signature = tool_call.thought_signature
            end
          end
        end
      end
    end

    # 根据 id 查找或定位最近的工具调用（旧逻辑保留，目前主要用 id 直查）。
    def find_tool_call(tool_call_id)
      if tool_call_id.nil?
        @tool_calls[@latest_tool_call]
      else
        @latest_tool_call_id = tool_call_id
        @tool_calls[tool_call_id]
      end
    end

    # 仅在 chunk 中给出非空值时更新 token 计数，避免被中间 chunk 的
    # nil 覆盖最终值。
    def count_tokens(chunk)
      @input_tokens = chunk.input_tokens if chunk.input_tokens
      @output_tokens = chunk.output_tokens if chunk.output_tokens
      @cached_tokens = chunk.cached_tokens if chunk.cached_tokens
      @cache_creation_tokens = chunk.cache_creation_tokens if chunk.cache_creation_tokens
      @thinking_tokens = chunk.thinking_tokens if chunk.thinking_tokens
    end

    # 按 chunk 内容类型分发到工具调用累加或文本累加。
    def handle_chunk_content(chunk)
      return accumulate_tool_calls(chunk.tool_calls) if chunk.tool_call?

      content_text = chunk.content || ''
      if content_text.is_a?(String)
        append_text_with_thinking(content_text)
      else
        @content << content_text.to_s
      end
    end

    # 把一段文本切分为正文与 `<think>` 标签内的思考，分别追加到
    # 各自的缓冲区。
    def append_text_with_thinking(text)
      content_chunk, thinking_chunk = extract_think_tags(text)
      @content << content_chunk
      @thinking_text << thinking_chunk if thinking_chunk
    end

    # 处理 chunk 中带结构化 `thinking` 字段的情况（Anthropic 等）。
    def append_thinking_from_chunk(chunk)
      thinking = chunk.thinking
      return unless thinking

      @thinking_text << thinking.text.to_s if thinking.text
      @thinking_signature ||= thinking.signature # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    # `<think>...</think>` 标签状态机的核心。
    #
    # 把传入文本与上一次累积的"未完整标签前缀"拼接，循环消费每段，
    # 当处于标签内部时用 {#consume_think_content}，否则用
    # {#consume_non_think_content}。返回 `[正文, 思考]`，思考为 nil
    # 表示本批未发现任何思考内容。
    def extract_think_tags(text)
      start_tag = '<think>'
      end_tag = '</think>'
      remaining = @pending_think_tag + text
      @pending_think_tag = +''

      output = +''
      thinking = +''

      until remaining.empty?
        remaining = if @inside_think_tag
                      consume_think_content(remaining, end_tag, thinking)
                    else
                      consume_non_think_content(remaining, start_tag, output)
                    end
      end

      [output, thinking.empty? ? nil : thinking]
    end

    # 处于 `<think>` 标签内：找 `</think>` 关闭标签。
    # 找到就把内容写入 thinking、退出标签状态、返回剩余字符串；
    # 找不到则把"末尾可能是标签前缀的部分"暂存起来，等下次 chunk 拼接。
    def consume_think_content(remaining, end_tag, thinking)
      end_index = remaining.index(end_tag)
      if end_index
        thinking << remaining.slice(0, end_index)
        @inside_think_tag = false
        remaining.slice((end_index + end_tag.length)..) || +''
      else
        suffix_len = longest_suffix_prefix(remaining, end_tag)
        thinking << remaining.slice(0, remaining.length - suffix_len)
        @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
        +''
      end
    end

    # 处于正文（非 think）状态：找 `<think>` 开启标签。
    # 同样处理"标签可能跨 chunk 切割"的边缘情况。
    def consume_non_think_content(remaining, start_tag, output)
      start_index = remaining.index(start_tag)
      if start_index
        output << remaining.slice(0, start_index)
        @inside_think_tag = true
        remaining.slice((start_index + start_tag.length)..) || +''
      else
        suffix_len = longest_suffix_prefix(remaining, start_tag)
        output << remaining.slice(0, remaining.length - suffix_len)
        @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
        +''
      end
    end

    # 求 text 末尾是否匹配 tag 的某个前缀，返回最长匹配长度。
    # 用于检测"标签被切到下一个 chunk"的边界情况，例如 text 末尾是
    # `<thi`、tag 是 `<think>`，则返回 4。
    def longest_suffix_prefix(text, tag)
      max = [text.length, tag.length - 1].min
      max.downto(1) do |len|
        return len if text.end_with?(tag[0, len])
      end
      0
    end
  end
end
