# frozen_string_literal: true

module RubyLLM
  module Providers
    class VertexAI
      # Chat methods for the Vertex AI implementation
      #
      # Vertex AI 与 Gemini 的请求体格式相同，差别仅在 URL：必须包含
      # GCP project_id 与 location。其他逻辑全部继承自 Gemini::Chat。
      module Chat
        def completion_url
          "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/publishers/google/models/#{@model}:generateContent" # rubocop:disable Layout/LineLength
        end
      end
    end
  end
end
