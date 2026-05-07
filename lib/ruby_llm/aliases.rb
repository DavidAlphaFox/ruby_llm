# frozen_string_literal: true

module RubyLLM
  # Manages model aliases for provider-specific versions
  #
  # 模型别名解析器。
  #
  # `aliases.json` 内容形如：
  #   {
  #     "claude-sonnet-4": {
  #       "anthropic": "claude-sonnet-4-20250514",
  #       "bedrock":   "anthropic.claude-sonnet-4-v1",
  #       "vertexai":  "claude-sonnet-4@20250514"
  #     }
  #   }
  #
  # 即同一个"友好名"在不同 provider 上对应不同的真实 ID。
  # 用户写 `RubyLLM.chat(model: 'claude-sonnet-4')` 时会被翻译成对应
  # provider 的实际 ID。
  class Aliases
    class << self
      # 解析别名。
      #
      # @param model_id [String] 用户写法（可能是别名也可能是真实 ID）
      # @param provider [Symbol, String, nil] 当前 provider
      # @return [String] 真实模型 ID；非别名时原样返回
      def resolve(model_id, provider = nil)
        return model_id unless aliases[model_id]

        if provider
          aliases[model_id][provider.to_s] || model_id
        else
          # 没指定 provider 时退回到第一个映射（按 JSON 中的顺序）。
          aliases[model_id].values.first || model_id
        end
      end

      # 别名表（懒加载）。
      def aliases
        @aliases ||= load_aliases
      end

      def aliases_file
        File.expand_path('aliases.json', __dir__)
      end

      # 从 gem 内置的 aliases.json 读取；文件不存在时返回空 hash。
      def load_aliases
        if File.exist?(aliases_file)
          JSON.parse(File.read(aliases_file))
        else
          {}
        end
      end

      # 重新加载（用于运行时刷新别名表后调用）。
      def reload!
        @aliases = load_aliases
      end
    end
  end
end
