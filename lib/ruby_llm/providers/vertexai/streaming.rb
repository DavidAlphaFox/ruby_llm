# frozen_string_literal: true

module RubyLLM
  module Providers
    class VertexAI
      # Streaming methods for the Vertex AI implementation
      #
      # 与 chat 类似，仅覆盖 URL（含 project / location 路径段）。
      # SSE 解析、build_chunk 等逻辑全部沿用 Gemini::Streaming。
      module Streaming
        def stream_url
          "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/publishers/google/models/#{@model}:streamGenerateContent?alt=sse" # rubocop:disable Layout/LineLength
        end
      end
    end
  end
end
