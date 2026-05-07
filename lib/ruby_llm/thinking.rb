# frozen_string_literal: true

module RubyLLM
  # Represents provider thinking output.
  #
  # 模型推理（"thinking" / "reasoning"）输出。
  #
  # OpenAI、Anthropic、Gemini 都支持以独立字段返回模型的思考过程：
  # - **text** —— 思考文本（可选，部分 provider 会加密不返回明文）
  # - **signature** —— 加密签名（Anthropic 专有），用于在多轮请求中
  #   把"思考链"原样回传给模型而无需解密
  #
  # 出于安全考虑，{#pretty_print} 把 signature 渲染为 `[REDACTED]`，
  # 防止它出现在调试输出/截图中。
  class Thinking
    # @return [String, nil]
    attr_reader :text, :signature

    # @param text [String, nil]
    # @param signature [String, nil]
    def initialize(text: nil, signature: nil)
      @text = text
      @signature = signature
    end

    # 工厂方法 —— 仅在 text/signature 至少一个有效时构造实例，
    # 空字符串视同 nil；全空时返回 nil（避免空 Thinking 对象）。
    #
    # @return [Thinking, nil]
    def self.build(text: nil, signature: nil)
      text = nil if text.is_a?(String) && text.empty?
      signature = nil if signature.is_a?(String) && signature.empty?

      return nil if text.nil? && signature.nil?

      new(text: text, signature: signature)
    end

    # 自定义 pp 输出：把 signature 字段隐藏为 `[REDACTED]`。
    def pretty_print(printer)
      printer.object_group(self) do
        printer.breakable
        printer.text 'text='
        printer.pp text
        printer.comma_breakable
        printer.text 'signature='
        printer.pp(signature ? '[REDACTED]' : nil)
      end
    end
  end

  class Thinking
    # Normalized config for thinking across providers.
    #
    # 跨 provider 的统一思考预算配置。
    #
    # `Chat#with_thinking(effort:, budget:)` 会构造此对象，再由各
    # provider 的 chat.rb 翻译成 provider 协议字段：
    # - OpenAI o-系列：`effort` → `reasoning_effort`
    # - Anthropic：`budget` → `thinking.budget_tokens`
    # - Gemini：`budget` → `thinking_config.thinking_budget`
    class Config
      # @return [String, nil] 思考强度（一般为 'low'/'medium'/'high'）
      # @return [Integer, nil] 思考 token 预算
      attr_reader :effort, :budget

      def initialize(effort: nil, budget: nil)
        @effort = effort.is_a?(Symbol) ? effort.to_s : effort
        @budget = budget
      end

      # 是否启用了思考（任一字段被设置即为启用）。
      def enabled?
        !effort.nil? || !budget.nil?
      end
    end
  end
end
