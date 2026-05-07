# frozen_string_literal: true

module RubyLLM
  module Providers
    class Anthropic
      # Embeddings methods of the Anthropic API integration
      #
      # 占位实现：Anthropic 不提供原生 embeddings API（推荐 Voyage AI）。
      # 用户调用 embed 会得到清晰的 Error 提示。
      module Embeddings
        private

        def embed
          raise Error "Anthropic doesn't support embeddings"
        end

        alias render_embedding_payload embed
        alias embedding_url embed
        alias parse_embedding_response embed
      end
    end
  end
end
