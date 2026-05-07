# frozen_string_literal: true

module RubyLLM
  module Model
    # A dynamic class for storing non-zero pricing values with flexible attribute access
    #
    # 单档价格的具体单价集合（动态属性容器）。
    #
    # 用 `method_missing` 把任意键暴露为读写器：
    #   tier.input_per_million          # 读
    #   tier.input_per_million = 0.005  # 写
    #
    # 设计取舍：不同 provider/类目下字段名各异（reasoning_output / cache_read /
    # cached_input...）；用动态属性避免每加一个字段就改类。
    # 内部把 0/nil 视为"未设置"，不入存储。
    class PricingTier
      def initialize(data = {})
        @values = {}

        data.each do |key, value|
          @values[key.to_sym] = value if value && value != 0.0
        end
      end

      # 动态读写：`*=` 写入，其他名按 key 读取。0/nil 写入会被忽略。
      def method_missing(method, *args)
        if method.to_s.end_with?('=')
          key = method.to_s.chomp('=').to_sym
          @values[key] = args.first if args.first && args.first != 0.0
        elsif @values.key?(method)
          @values[method]
        end
      end

      def respond_to_missing?(method, include_private = false)
        method.to_s.end_with?('=') || @values.key?(method.to_sym) || super
      end

      def to_h
        @values
      end
    end
  end
end
