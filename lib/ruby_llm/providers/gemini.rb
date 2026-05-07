# frozen_string_literal: true

module RubyLLM
  module Providers
    # Native Gemini API implementation
    #
    # Google Gemini API（generativelanguage.googleapis.com）原生集成。
    # 协议与 OpenAI 完全不同：消息以 `contents` 数组 + `parts` 子结构
    # 表示、工具叫 `tools.functionDeclarations`、流式用查询串
    # `?alt=sse` 触发。VertexAI 是其企业版，继承本类。
    class Gemini < Provider
      include Gemini::Chat
      include Gemini::Embeddings
      include Gemini::Images
      include Gemini::Models
      include Gemini::Transcription
      include Gemini::Streaming
      include Gemini::Tools
      include Gemini::Media

      def api_base
        @config.gemini_api_base || 'https://generativelanguage.googleapis.com/v1beta'
      end

      # Gemini 用专有的 x-goog-api-key 头做认证。
      def headers
        {
          'x-goog-api-key' => @config.gemini_api_key
        }
      end

      class << self
        def capabilities
          Gemini::Capabilities
        end

        def configuration_options
          %i[gemini_api_key gemini_api_base]
        end

        def configuration_requirements
          %i[gemini_api_key]
        end
      end
    end
  end
end
