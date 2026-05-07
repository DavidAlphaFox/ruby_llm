# frozen_string_literal: true

module RubyLLM
  # Represents token usage for a response.
  #
  # 单次响应的 token 计数（自 1.15 起跨 provider 统一口径）。
  #
  # 字段语义：
  # - **input** —— 标准输入 token（不含缓存读/写）
  # - **output** —— 输出 token
  # - **cached** —— 缓存命中（读取）的 token；别名 `cache_read`
  # - **cache_creation** —— 缓存创建（写入）的 token；别名 `cache_write`
  # - **thinking** —— 推理 token；别名 `reasoning`（OpenAI 命名）
  #
  # 若需要"请求侧总输入活动"，用 `input + cached + cache_creation`。
  class Tokens
    attr_reader :input, :output, :cached, :cache_creation, :thinking

    # 构造方法支持两个推理别名 `:thinking` 与 `:reasoning`，使用前者优先。
    # rubocop:disable Metrics/ParameterLists
    def initialize(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil, reasoning: nil)
      @input = input
      @output = output
      @cached = cached
      @cache_creation = cache_creation
      @thinking = thinking || reasoning
    end
    # rubocop:enable Metrics/ParameterLists

    # 工厂：当所有字段都为 nil 时返回 nil（避免出现"空 Tokens"对象）。
    #
    # @return [Tokens, nil]
    # rubocop:disable Metrics/ParameterLists
    def self.build(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil, reasoning: nil)
      return nil if [input, output, cached, cache_creation, thinking, reasoning].all?(&:nil?)

      new(
        input: input,
        output: output,
        cached: cached,
        cache_creation: cache_creation,
        thinking: thinking,
        reasoning: reasoning
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # 序列化为带 `_tokens` 后缀的 hash（与 ActiveRecord 列对齐）。
    def to_h
      {
        input_tokens: input,
        output_tokens: output,
        cached_tokens: cached,
        cache_creation_tokens: cache_creation,
        thinking_tokens: thinking
      }.compact
    end

    # @return [Integer, nil] thinking 的别名
    def reasoning = thinking
    # @return [Integer, nil] cached 的别名（缓存读取）
    def cache_read = cached
    # @return [Integer, nil] cache_creation 的别名（缓存写入）
    def cache_write = cache_creation
  end
end
