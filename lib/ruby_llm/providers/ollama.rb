# frozen_string_literal: true

module RubyLLM
  module Providers
    # Ollama API integration.
    #
    # 本地运行的 Ollama 服务（默认 `http://localhost:11434`）。
    # 提供 OpenAI 兼容 API；`local?` 为 true，可使用任意模型而无需
    # 模型注册表收录。
    class Ollama < OpenAI
      include Ollama::Chat
      include Ollama::Media
      include Ollama::Models

      def api_base
        @config.ollama_api_base
      end

      def headers
        return {} unless @config.ollama_api_key

        { 'Authorization' => "Bearer #{@config.ollama_api_key}" }
      end

      class << self
        def configuration_options
          %i[ollama_api_base ollama_api_key]
        end

        def configuration_requirements
          %i[ollama_api_base]
        end

        def local?
          true
        end

        def capabilities
          Ollama::Capabilities
        end
      end
    end
  end
end
