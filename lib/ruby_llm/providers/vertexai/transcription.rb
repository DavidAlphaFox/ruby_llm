# frozen_string_literal: true

module RubyLLM
  module Providers
    class VertexAI
      # Vertex AI specific helpers for audio transcription
      #
      # 转写复用 Gemini 的"用 generateContent 让多模态模型转写"思路，
      # 仅覆盖 URL（与 Vertex chat 同款 project/location 路径）。
      module Transcription
        private

        def transcription_url(model)
          "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/publishers/google/models/#{model}:generateContent" # rubocop:disable Layout/LineLength
        end
      end
    end
  end
end
