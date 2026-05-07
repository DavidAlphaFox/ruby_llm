# frozen_string_literal: true

module RubyLLM
  module Providers
    # xAI API integration
    #
    # xAI（Grok 系列）提供 OpenAI 兼容 API；继承 OpenAI 后只覆盖
    # base url 与认证头。
    class XAI < OpenAI
      include XAI::Chat
      include XAI::Models

      def api_base
        'https://api.x.ai/v1'
      end

      def headers
        {
          'Authorization' => "Bearer #{@config.xai_api_key}",
          'Content-Type' => 'application/json'
        }
      end

      class << self
        def configuration_options
          %i[xai_api_key]
        end

        def configuration_requirements
          %i[xai_api_key]
        end
      end
    end
  end
end
