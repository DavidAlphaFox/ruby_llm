# frozen_string_literal: true

module RubyLLM
  module Providers
    # Mistral API integration.
    #
    # Mistral 自家 API 基本兼容 OpenAI。继承 OpenAI 后只覆盖 base url、
    # 认证头与个别 chat 字段差异。
    class Mistral < OpenAI
      include Mistral::Chat
      include Mistral::Models
      include Mistral::Embeddings

      def api_base
        'https://api.mistral.ai/v1'
      end

      def headers
        {
          'Authorization' => "Bearer #{@config.mistral_api_key}"
        }
      end

      class << self
        def capabilities
          Mistral::Capabilities
        end

        def configuration_options
          %i[mistral_api_key]
        end

        def configuration_requirements
          %i[mistral_api_key]
        end
      end
    end
  end
end
