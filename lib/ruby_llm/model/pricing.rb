# frozen_string_literal: true

module RubyLLM
  module Model
    # A collection that manages and provides access to different categories of pricing information
    #
    # 价格表（按计费类目分组）。
    #
    # 一个模型可能有多个计费类目：text_tokens、images、audio_tokens、
    # embeddings；每个类目下又有 standard / batch 两档（{PricingCategory}）；
    # 每档下有具体单价（{PricingTier}）。
    #
    # 通过 `method_missing` 把类目名暴露成方法 ——
    # `pricing.text_tokens.input` 即可拿到标准价的输入单价。访问不存在
    # 的类目会返回空 PricingCategory（避免 nil 报错）。
    class Pricing
      def initialize(data)
        @data = {}

        %i[text_tokens images audio_tokens embeddings].each do |category|
          @data[category] = PricingCategory.new(data[category]) if data[category] && !empty_pricing?(data[category])
        end
      end

      # 把 `text_tokens` 等类目名翻译为 hash 取值（缺失时返回空 category）。
      def method_missing(method, *args)
        if respond_to_missing?(method)
          @data[method.to_sym] || PricingCategory.new
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        %i[text_tokens images audio_tokens embeddings].include?(method.to_sym) || super
      end

      def to_h
        @data.transform_values(&:to_h)
      end

      private

      # 判定一个类目数据是否实质为空（所有 tier 下所有值都是 nil/0）。
      def empty_pricing?(data)
        return true unless data

        %i[standard batch].each do |tier|
          next unless data[tier]

          data[tier].each_value do |value|
            return false if value && value != 0.0
          end
        end

        true
      end
    end
  end
end
