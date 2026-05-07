# frozen_string_literal: true

module RubyLLM
  module Model
    # Represents pricing tiers for different usage categories (standard and batch)
    #
    # 单个计费类目下的两档价格（`standard` / `batch`）。
    #
    # 大多数 provider 提供"批处理 batch API"折扣价（通常 50% off）。
    # 顶层方法（`#input`、`#output`、`#cache_read_input` 等）总是返回
    # standard 价；通过 `pricing[:batch]` 可访问批处理价。
    class PricingCategory
      # @return [PricingTier, nil] 标准档单价
      # @return [PricingTier, nil] 批处理档单价
      attr_reader :standard, :batch

      def initialize(data = {})
        @standard = PricingTier.new(data[:standard] || {}) unless empty_tier?(data[:standard])
        @batch = PricingTier.new(data[:batch] || {}) unless empty_tier?(data[:batch])
      end

      # @return [Float, nil] 输入单价（每百万 token）
      def input = standard&.input_per_million
      # @return [Float, nil] 输出单价
      def output = standard&.output_per_million

      # 缓存读取单价 —— 兼容两个字段名（`cache_read_input_per_million`
      # 与 `cached_input_per_million`）。
      def cache_read_input
        standard&.cache_read_input_per_million || standard&.cached_input_per_million
      end

      # 缓存写入单价 —— 兼容两个字段名。
      def cache_write_input
        standard&.cache_write_input_per_million || standard&.cache_creation_input_per_million
      end

      # 推理输出单价（OpenAI o-系列等收费高于普通 output）。
      def reasoning_output = standard&.reasoning_output_per_million

      alias cached_input cache_read_input
      alias cache_creation_input cache_write_input

      # 索引访问：`pricing[:batch]` / `pricing[:standard]`。
      def [](key)
        key == :batch ? batch : standard
      end

      def to_h
        result = {}
        result[:standard] = standard.to_h if standard
        result[:batch] = batch.to_h if batch
        result
      end

      private

      # tier 数据若全为 nil/0，视为不存在。
      def empty_tier?(tier_data)
        return true unless tier_data

        tier_data.values.all? { |v| v.nil? || v == 0.0 }
      end
    end
  end
end
