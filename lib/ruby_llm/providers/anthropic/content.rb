# frozen_string_literal: true

module RubyLLM
  module Providers
    class Anthropic
      # Helper for constructing Anthropic native content blocks.
      #
      # 构造 Anthropic 原生 content block 的语法糖。返回的对象是
      # {RubyLLM::Content::Raw}，会被 Media 模块直接传给 API（绕过
      # 标准格式化），常用于：
      # - 显式启用 prompt caching：`Content.new('long text', cache: true)`
      # - 提供完整原生 parts：`Content.new(parts: [{type: 'text', ...}])`
      class Content
        class << self
          # @param text [String, nil]
          # @param cache [Boolean] 是否启用临时缓存（cache_control: ephemeral）
          # @param cache_control [Hash, nil] 显式 cache_control 字段（覆盖 cache:）
          # @param parts [Array<Hash>, nil] 原生 parts，与 text 互斥
          # @param extras [Hash] 写入 block 的其他字段
          # @return [RubyLLM::Content::Raw]
          def new(text = nil, cache: false, cache_control: nil, parts: nil, **extras)
            payload = resolve_payload(
              text: text,
              parts: parts,
              cache: cache,
              cache_control: cache_control,
              extras: extras
            )

            RubyLLM::Content::Raw.new(payload)
          end

          private

          def resolve_payload(text:, parts:, cache:, cache_control:, extras:)
            return Array(parts) if parts

            raise ArgumentError, 'text or parts must be provided' if text.nil?

            block = { type: 'text', text: text }.merge(extras)
            control = determine_cache_control(cache_control, cache)
            block[:cache_control] = control if control

            [block]
          end

          def determine_cache_control(cache_control, cache_flag)
            return cache_control if cache_control

            { type: 'ephemeral' } if cache_flag
          end
        end
      end
    end
  end
end
