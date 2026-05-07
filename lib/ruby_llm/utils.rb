# frozen_string_literal: true

module RubyLLM
  # Provides utility functions for data manipulation within the RubyLLM library
  #
  # 内部工具函数集合。
  #
  # 故意不依赖 ActiveSupport（gem 的核心承诺之一是"零 Rails 依赖"），
  # 因此自带了 deep_merge / deep_dup / deep_stringify_keys 等实现。
  module Utils
    module_function

    # 兼容字符串/符号 key 的 hash 取值。
    def hash_get(hash, key)
      hash[key.to_sym] || hash[key.to_s]
    end

    # 把任意输入规范化为数组：
    # - Array 原样返回
    # - Hash 包成单元素数组（保护 hash 不被 `Array(h)` 拆成元组数组）
    # - 其他 → Array(item)
    def to_safe_array(item)
      case item
      when Array
        item
      when Hash
        [item]
      else
        Array(item)
      end
    end

    # 安全的 Time 解析：nil 透传。
    def to_time(value)
      return unless value

      value.is_a?(Time) ? value : Time.parse(value.to_s)
    end

    # 安全的 Date 解析：nil 透传。
    def to_date(value)
      return unless value

      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end

    # 深度合并两个 hash（嵌套 hash 也递归合并；非 hash 值由 overrides 胜出）。
    def deep_merge(original, overrides)
      original.merge(overrides) do |_key, original_value, overrides_value|
        if original_value.is_a?(Hash) && overrides_value.is_a?(Hash)
          deep_merge(original_value, overrides_value)
        else
          overrides_value
        end
      end
    end

    # 深拷贝 hash/array/普通对象。`dup` 不可用时（symbol/integer 等
    # 不可变值）原样返回。
    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), duped|
          duped[deep_dup(key)] = deep_dup(val)
        end
      when Array
        value.map { |item| deep_dup(item) }
      else
        begin
          value.dup
        rescue TypeError
          value
        end
      end
    end

    # 把所有 hash key（含嵌套）转为字符串。值若是 Symbol 也转字符串。
    # 用于把 Ruby 风格的 hash 序列化成对外 JSON。
    def deep_stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), result|
          result[key.to_s] = deep_stringify_keys(val)
        end
      when Array
        value.map { |item| deep_stringify_keys(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    # deep_stringify_keys 的反向：所有 hash key 转为符号。用于解析
    # 外部 JSON 后内部以符号 key 操作。
    def deep_symbolize_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), result|
          symbolized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          result[symbolized_key] = deep_symbolize_keys(val)
        end
      when Array
        value.map { |item| deep_symbolize_keys(item) }
      else
        value
      end
    end
  end
end
