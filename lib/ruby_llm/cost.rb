# frozen_string_literal: true

module RubyLLM
  # Represents the cost of token usage for a model response.
  #
  # 一次响应（或一段会话累计）的费用对象。
  #
  # 设计要点：
  # 1. **两种构造形态**：单条消息基于 `tokens + model` 实时计算（按
  #    每百万 token 单价折算）；多条消息聚合时用 {.aggregate}，把各条
  #    的金额逐项加和（缺失字段会被传染为 nil 而不是 0）。
  # 2. **缺失感知**：若某条消息有 token 但 model 注册表里没价格，
  #    `total` 返回 nil 而非低估值；调用方据此知道"价格未知"。
  # 3. **图像计费分支**：`category: :images` 时按图像类目价格计算，
  #    并支持 `input_details` 描述 `text + image` 混合输入的计费。
  # 4. **思考 token**：仅在 provider 把 reasoning 价格与 output 价格
  #    分别定价时（{#thinking_priced_separately?}）才单独计费，
  #    否则视为已包含在 output 里。
  class Cost
    # 计费组件：`:input`、`:output`、`:cache_read`、`:cache_write`、`:thinking`。
    COMPONENTS = %i[input output cache_read cache_write thinking].freeze
    # 单价基准：每百万 token。
    PER_MILLION = 1_000_000.0

    # @return [RubyLLM::Tokens, nil]
    # @return [RubyLLM::Model::Info, nil]
    # @return [Symbol] 计费类目（`:text_tokens` / `:images` / ...）
    attr_reader :tokens, :model, :category

    # 把多条 Cost 聚合为一条总费用。
    #
    # 关键细节：当任一原始 cost 在某 component 上"missing"（有 token 无
    # 价格）时，聚合结果在该 component 上也标记 missing —— 即 total
    # 返回 nil。这种"传染性 nil"避免了"漏算价格被静悄悄当成 0"。
    #
    # @param costs [Array<Cost>]
    # @return [Cost]
    def self.aggregate(costs)
      costs = costs.compact.select(&:tokens?)
      return new(amounts: {}, has_tokens: false) if costs.empty?

      missing = COMPONENTS.select do |component|
        costs.any? { |cost| cost.missing?(component) }
      end

      amounts = COMPONENTS.to_h do |component|
        [component, missing.include?(component) ? nil : aggregate_component(costs, component)]
      end

      new(amounts:, missing:, has_tokens: true)
    end

    # @param tokens [RubyLLM::Tokens, nil] token 计数
    # @param model [String, Symbol, RubyLLM::Model::Info, #to_llm, nil]
    # @param amounts [Hash{Symbol => Float}, nil] 聚合模式下直接给出金额
    # @param missing [Array<Symbol>] 缺失价格的组件列表
    # @param has_tokens [Boolean, nil] 显式覆盖"是否有 token"判定
    # @param category [Symbol] 计费类目，默认 `:text_tokens`
    # @param input_details [Hash, nil] 图像输入的明细
    # rubocop:disable Metrics/ParameterLists
    def initialize(tokens: nil, model: nil, amounts: nil, missing: [], has_tokens: nil, category: :text_tokens,
                   input_details: nil)
      @tokens = tokens
      @model = normalize_model(model)
      @amounts = amounts
      @missing = missing
      @has_tokens = has_tokens
      @category = category.to_sym
      @input_details = input_details
    end
    # rubocop:enable Metrics/ParameterLists

    # @!group 各组件费用（USD）
    def input         = amount_for(:input)
    def output        = amount_for(:output)
    def cache_read    = amount_for(:cache_read)
    def cache_write   = amount_for(:cache_write)
    def thinking      = amount_for(:thinking)
    # @!endgroup

    alias reasoning thinking

    alias cached_input cache_read
    alias cache_creation cache_write

    # 总费用（USD）。
    # 任一组件 missing 时返回 nil（语义：价格未知，拒绝低估）。
    #
    # @return [Float, nil]
    def total
      return nil unless tokens?
      return nil if COMPONENTS.any? { |component| missing?(component) }

      costs = COMPONENTS.filter_map { |component| public_send(component) }
      return nil if costs.empty?

      costs.sum
    end

    def to_h
      {
        input: input,
        output: output,
        cache_read: cache_read,
        cache_write: cache_write,
        thinking: thinking,
        total: total
      }.compact
    end

    def tokens?
      return @has_tokens unless @has_tokens.nil?

      COMPONENTS.any? { |component| !tokens_for(component).nil? }
    end

    def missing?(component)
      return @missing.include?(component) if aggregate?
      return image_input_missing? if component == :input && detailed_image_input?
      return false if component == :thinking && !thinking_priced_separately?

      tokens = tokens_for(component)
      tokens.to_i.positive? && price_for(component).nil?
    end

    private_class_method def self.aggregate_component(costs, component)
      values = costs.filter_map { |cost| cost.public_send(component) }
      values.empty? ? nil : values.sum
    end

    private

    def amount_for(component)
      return @amounts[component] if aggregate?
      return image_input_amount if component == :input && detailed_image_input?

      token_count = tokens_for(component)
      return nil if token_count.nil?

      token_count = token_count.to_i
      return 0.0 if token_count.zero?

      price = price_for(component)
      return nil unless price

      token_count * price / PER_MILLION
    end

    def aggregate?
      !@amounts.nil?
    end

    def tokens_for(component)
      return unless tokens

      case component
      when :input
        tokens.input
      when :output
        tokens.output
      when :cache_read
        tokens.cache_read
      when :cache_write
        tokens.cache_write
      when :thinking
        tokens.thinking if thinking_priced_separately?
      end
    end

    def price_for(component)
      case component
      when :input
        text_pricing.input
      when :output
        output_pricing.output
      when :cache_read
        text_pricing.cache_read_input
      when :cache_write
        text_pricing.cache_write_input
      when :thinking
        text_pricing.reasoning_output
      end
    end

    def text_pricing
      model&.pricing&.text_tokens || RubyLLM::Model::PricingCategory.new
    end

    def image_pricing
      model&.pricing&.images || RubyLLM::Model::PricingCategory.new
    end

    def output_pricing
      image_cost? && image_pricing.output ? image_pricing : text_pricing
    end

    def image_cost?
      %i[image images].include?(category)
    end

    def detailed_image_input?
      image_cost? && @input_details.is_a?(Hash) && image_input_parts.any? { |_, tokens, _| !tokens.nil? }
    end

    def image_input_amount
      return nil if image_input_missing?

      image_input_parts.filter_map do |_, token_count, price|
        next if token_count.nil? || token_count.to_i.zero?

        token_count.to_i * price / PER_MILLION
      end.sum
    end

    def image_input_missing?
      image_input_parts.any? do |_, token_count, price|
        token_count.to_i.positive? && price.nil?
      end
    end

    def image_input_parts
      [
        [:text, input_detail('text_tokens'), text_pricing.input],
        [:image, input_detail('image_tokens'), image_pricing.input || text_pricing.input]
      ]
    end

    def input_detail(key)
      @input_details[key] || @input_details[key.to_sym]
    end

    def thinking_priced_separately?
      reasoning_price = text_pricing.reasoning_output
      return false unless reasoning_price

      output_price = text_pricing.output
      output_price.nil? || reasoning_price != output_price
    end

    def normalize_model(model)
      return RubyLLM.models.find(model.to_s) if model.is_a?(String) || model.is_a?(Symbol)
      return model.to_llm if model.respond_to?(:to_llm)
      return model if model.respond_to?(:pricing)

      nil
    rescue ModelNotFoundError
      nil
    end
  end
end
