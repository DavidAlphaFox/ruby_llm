# frozen_string_literal: true

module RubyLLM
  module Providers
    # Anthropic Claude API integration.
    #
    # Anthropic 与 OpenAI 协议差异较大：用 `x-api-key` 头认证、
    # 必须发送 `anthropic-version` 头、支持加密 thinking signature、
    # tools/messages/stream 协议格式独立。
    #
    # 通过 mixin 拆分实现：Chat（核心补全）、Streaming（SSE）、
    # Tools（function calling）、Media（视觉/PDF）、Models（列表）、
    # Embeddings（实际由 Voyage 等第三方接 ——目前本 mixin 占位）。
    class Anthropic < Provider
      include Anthropic::Chat
      include Anthropic::Embeddings
      include Anthropic::Media
      include Anthropic::Models
      include Anthropic::Streaming
      include Anthropic::Tools

      def api_base
        @config.anthropic_api_base || 'https://api.anthropic.com'
      end

      # 注意：Anthropic 用 x-api-key 头而非 Bearer；同时强制要求
      # anthropic-version 头声明 API 版本。
      def headers
        {
          'x-api-key' => @config.anthropic_api_key,
          'anthropic-version' => '2023-06-01'
        }
      end

      class << self
        def capabilities
          Anthropic::Capabilities
        end

        def configuration_options
          %i[anthropic_api_key anthropic_api_base]
        end

        def configuration_requirements
          %i[anthropic_api_key]
        end
      end
    end
  end
end
