# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Models methods of the OpenAI API integration
      #
      # 调用 `/v1/models` 拉取可用模型列表。
      # OpenAI 不在 API 中返回 context_window / pricing / capabilities，
      # 因此从 {Capabilities} 模块按 model_id 模式匹配补充元数据。
      module Models
        module_function

        def models_url
          'models'
        end

        def parse_list_models_response(response, slug, capabilities)
          Array(response.body['data']).map do |model_data|
            model_id = model_data['id']

            Model::Info.new(
              id: model_id,
              name: model_id,
              provider: slug,
              created_at: model_data['created'] ? Time.at(model_data['created']) : nil,
              context_window: capabilities.context_window_for(model_id),
              max_output_tokens: capabilities.max_tokens_for(model_id),
              capabilities: capabilities.critical_capabilities_for(model_id),
              pricing: capabilities.pricing_for(model_id),
              metadata: {
                object: model_data['object'],
                owned_by: model_data['owned_by']
              }
            )
          end
        end
      end
    end
  end
end
