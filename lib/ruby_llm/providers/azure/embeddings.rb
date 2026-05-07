# frozen_string_literal: true

module RubyLLM
  module Providers
    class Azure
      # Embeddings methods of the Azure AI Foundry API integration
      #
      # 端点 URL 走 {Azure#azure_endpoint(:embeddings)}，请求体格式
      # 与 OpenAI 一致。Azure 始终把 input 包成数组（即使单条）。
      module Embeddings
        module_function

        def embedding_url(...)
          azure_endpoint(:embeddings)
        end

        def render_embedding_payload(text, model:, dimensions:)
          {
            model: model,
            input: [text].flatten,
            dimensions: dimensions
          }.compact
        end
      end
    end
  end
end
