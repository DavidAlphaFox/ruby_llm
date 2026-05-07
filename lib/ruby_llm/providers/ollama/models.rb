# frozen_string_literal: true

module RubyLLM
  module Providers
    class Ollama
      # Models methods for the Ollama API integration
      #
      # Ollama 的 `/v1/models` 列表返回 OpenAI 兼容字段，但不含
      # context_window/pricing 等。本地模型默认假定支持 streaming /
      # function_calling / structured_output / vision；用户可在
      # 模型注册表中覆盖。
      module Models
        def models_url
          'models'
        end

        def parse_list_models_response(response, slug, _capabilities)
          data = response.body['data'] || []
          data.map do |model|
            Model::Info.new(
              id: model['id'],
              name: model['id'],
              provider: slug,
              family: 'ollama',
              created_at: model['created'] ? Time.at(model['created']) : nil,
              modalities: {
                input: %w[text image],
                output: %w[text]
              },
              capabilities: %w[streaming function_calling structured_output vision],
              pricing: {},
              metadata: {
                owned_by: model['owned_by']
              }
            )
          end
        end
      end
    end
  end
end
