# frozen_string_literal: true

require 'active_support/core_ext/object/blank'
require 'json'

module RubyLLM
  module ActiveRecord
    # Shared helpers for parsing serialized payloads on ActiveRecord-backed models.
    #
    # 解析 AR 列中持久化 payload 的共享工具。
    #
    # AR 模型的 `arguments` / `content` 列可能是序列化的 JSON 字符串、
    # 已反序列化的 Hash/Array、或纯文本。这里的 helpers 兼容这三种
    # 形态，专门用于抽取 `error` 字段（工具调用失败的标准错误约定）。
    module PayloadHelpers
      private

      # 从 payload 中提取 error 文本。
      #
      # @param value [String, Hash, Array, nil]
      # @return [String, nil] 若 payload 不是 hash 或不含 error 则返回 nil
      def payload_error_message(value)
        payload = parse_payload(value)
        return unless payload.is_a?(Hash)

        payload['error'] || payload[:error]
      end

      # 把 value 容错地解析为对象：
      # - 已是 Hash/Array 直接返回
      # - 空值（nil/空串）返回 nil
      # - 否则尝试 JSON.parse，失败时返回 nil
      def parse_payload(value)
        return value if value.is_a?(Hash) || value.is_a?(Array)
        return if value.blank?

        JSON.parse(value)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
