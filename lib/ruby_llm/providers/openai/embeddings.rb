# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Embeddings methods of the OpenAI API integration
      #
      # OpenAI `/v1/embeddings` 协议实现。当输入是单字符串时，把
      # `data[0].embedding` 解包为单维向量；输入是数组时返回二维向量。
      module Embeddings
        module_function

        def embedding_url(...)
          'embeddings'
        end

        def render_embedding_payload(text, model:, dimensions:)
          {
            model: model,
            input: text,
            dimensions: dimensions
          }.compact
        end

        def parse_embedding_response(response, model:, text:)
          data = response.body
          input_tokens = data.dig('usage', 'prompt_tokens') || 0
          vectors = data['data'].map { |d| d['embedding'] }
          vectors = vectors.first if vectors.length == 1 && !text.is_a?(Array)

          Embedding.new(vectors:, model:, input_tokens:)
        end
      end
    end
  end
end
