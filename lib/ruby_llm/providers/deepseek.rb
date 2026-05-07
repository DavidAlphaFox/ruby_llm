# frozen_string_literal: true

module RubyLLM
  module Providers
    # DeepSeek API integration.
    #
    # DeepSeek 提供 OpenAI 兼容 API；继承 OpenAI 后只覆盖 base url、
    # 认证头与少量 chat 行为差异（见 `DeepSeek::Chat`）。
    class DeepSeek < OpenAI
      include DeepSeek::Chat

      def api_base
        @config.deepseek_api_base || 'https://api.deepseek.com'
      end

      def headers
        {
          'Authorization' => "Bearer #{@config.deepseek_api_key}"
        }
      end

      class << self
        def capabilities
          DeepSeek::Capabilities
        end

        def configuration_options
          %i[deepseek_api_key deepseek_api_base]
        end

        def configuration_requirements
          %i[deepseek_api_key]
        end
      end
    end
  end
end
