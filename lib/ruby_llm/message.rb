# frozen_string_literal: true

module RubyLLM
  # A single message in a chat conversation.
  #
  # 一条消息 —— 会话的最小单位。
  #
  # 一个 `Message` 同时承载多种"形态"的内容：
  # - **role 决定语义**：`:system`（系统指令）、`:user`（用户输入）、
  #   `:assistant`（模型回复）、`:tool`（工具结果）。
  # - **content** 可以是字符串、{Content}（文本+附件）、或工具结果的
  #   原生数据；为方便消费者，{#content} 在简单字符串场景下会自动解包。
  # - **tool_calls** 仅出现在 assistant 消息上，包含模型希望调用的工具列表。
  # - **tool_call_id** 仅出现在 tool 消息上，标识它是哪一次工具调用的结果。
  # - **thinking** 推理内容（{Thinking}）；**tokens** token 计数（{Tokens}）。
  # - **raw** 原始 HTTP 响应（不参与 inspect 输出，避免日志膨胀）。
  class Message
    # 合法 role 集合。
    ROLES = %i[system user assistant tool].freeze

    # @!attribute [r] role
    #   @return [Symbol] `:system`/`:user`/`:assistant`/`:tool`
    # @!attribute [r] model_id
    #   @return [String, nil]
    # @!attribute [r] tool_calls
    #   @return [Hash{String => RubyLLM::ToolCall}, nil]
    # @!attribute [r] tool_call_id
    #   @return [String, nil] 仅 role=:tool 时存在
    # @!attribute [r] raw
    #   @return [Faraday::Response, nil] 原始响应（被 instance_variables 隐藏）
    # @!attribute [r] thinking
    #   @return [RubyLLM::Thinking, nil]
    # @!attribute [r] tokens
    #   @return [RubyLLM::Tokens, nil]
    attr_reader :role, :model_id, :tool_calls, :tool_call_id, :raw, :thinking, :tokens
    attr_writer :content

    # @param options [Hash]
    # @option options [Symbol, String] :role 必填
    # @option options [String, Content, Hash] :content 必填
    # @option options [String] :model_id
    # @option options [Hash] :tool_calls
    # @option options [String] :tool_call_id
    # @option options [RubyLLM::Tokens] :tokens 直接给出整体 tokens 对象
    # @option options [Integer] :input_tokens / :output_tokens / :cached_tokens
    #   / :cache_creation_tokens / :thinking_tokens / :reasoning_tokens
    #   逐字段指定（与 :tokens 二选一）
    # @option options [RubyLLM::Thinking] :thinking
    # @option options [Faraday::Response] :raw
    # @raise [InvalidRoleError] role 不在 {ROLES} 内
    def initialize(options = {})
      @role = options.fetch(:role).to_sym
      @tool_calls = options[:tool_calls]
      @content = normalize_content(options.fetch(:content), role: @role, tool_calls: @tool_calls)
      @model_id = options[:model_id]
      @tool_call_id = options[:tool_call_id]
      @tokens = options[:tokens] || Tokens.build(
        input: options[:input_tokens],
        output: options[:output_tokens],
        cached: options[:cached_tokens],
        cache_creation: options[:cache_creation_tokens],
        thinking: options[:thinking_tokens],
        reasoning: options[:reasoning_tokens]
      )
      @raw = options[:raw]
      @thinking = options[:thinking]

      ensure_valid_role
    end

    # 取消息内容。当内容是仅含文本（无附件）的 {Content} 时**自动解包**
    # 为字符串，方便上层消费；多模态/工具结果则原样返回。
    #
    # @return [String, RubyLLM::Content, Object]
    def content
      if @content.is_a?(Content) && @content.text && @content.attachments.empty?
        @content.text
      else
        @content
      end
    end

    # 该消息是否携带工具调用（assistant 提议调用工具）。
    def tool_call?
      !tool_calls.nil? && !tool_calls.empty?
    end

    # 该消息是否是工具调用结果（role=:tool）。
    def tool_result?
      !tool_call_id.nil? && !tool_call_id.empty?
    end

    # 工具结果消息的内容（其他类型消息返回 nil）。
    def tool_results
      content if tool_result?
    end

    # @return [Integer, nil] 输入 token 数
    def input_tokens = tokens&.input
    # @return [Integer, nil] 输出 token 数
    def output_tokens = tokens&.output
    # @return [Integer, nil] 缓存命中（读取）的 token 数
    def cached_tokens = tokens&.cached
    # @return [Integer, nil] 缓存创建（写入）的 token 数
    def cache_creation_tokens = tokens&.cache_creation
    # @return [Integer, nil] cached 的别名（语义更明确）
    def cache_read_tokens = tokens&.cache_read
    # @return [Integer, nil] cache_creation 的别名（语义更明确）
    def cache_write_tokens = tokens&.cache_write
    # @return [Integer, nil] 推理（thinking）token 数
    def thinking_tokens = tokens&.thinking
    # @return [Integer, nil] thinking 的别名（OpenAI 用 reasoning 一词）
    def reasoning_tokens = tokens&.thinking

    # 计算本条消息的费用。
    #
    # @param model [RubyLLM::Model::Info, nil] 显式指定计费模型；
    #   为 nil 时通过 {#model_info} 在注册表中按 model_id 查
    # @return [RubyLLM::Cost]
    def cost(model: nil)
      Cost.new(tokens:, model: model || model_info)
    end

    # 转为可序列化 hash（用于日志/持久化）。空字段会被 compact 掉。
    def to_h
      {
        role: role,
        content: content,
        model_id: model_id,
        tool_calls: tool_calls,
        tool_call_id: tool_call_id,
        thinking: thinking&.text,
        thinking_signature: thinking&.signature
      }.merge(tokens ? tokens.to_h : {}).compact
    end

    # inspect 时**隐藏 @raw**，避免打印整段 HTTP 响应。
    def instance_variables
      super - [:@raw]
    end

    # 在注册表中查到的模型元数据；找不到时返回 nil 而非抛错。
    #
    # @return [RubyLLM::Model::Info, nil]
    def model_info
      return unless model_id

      @model_info ||= RubyLLM.models.find(model_id)
    rescue ModelNotFoundError
      nil
    end

    private

    # 把 content 输入规范化为 String / Content / 原生数据。
    # 特例：assistant 角色 + content 为 nil + 有工具调用 → 用空串
    # （这是 OpenAI 等 API 在仅返回工具调用时的常见空 content 情形）。
    def normalize_content(content, role:, tool_calls:)
      return '' if role == :assistant && content.nil? && tool_calls && !tool_calls.empty?

      case content
      when String then Content.new(content)
      when Hash then Content.new(content[:text], content)
      else content
      end
    end

    def ensure_valid_role
      raise InvalidRoleError, "Expected role to be one of: #{ROLES.join(', ')}" unless ROLES.include?(role)
    end
  end
end
