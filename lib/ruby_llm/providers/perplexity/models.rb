# frozen_string_literal: true

module RubyLLM
  module Providers
    class Perplexity
      # Models methods of the Perplexity API integration
      #
      # Perplexity 没有 `/models` 列表端点；本模块返回静态 5 款 sonar
      # 模型列表，所有元数据来自 {Capabilities} 查表。
      module Models
        # 当前支持的全部 Perplexity 模型（按家族硬编码）。
        MODEL_IDS = %w[
          sonar
          sonar-pro
          sonar-reasoning
          sonar-reasoning-pro
          sonar-deep-research
        ].freeze

        # 覆盖 list_models —— 不发 HTTP 请求，直接返回静态列表。
        def list_models(**)
          slug = 'perplexity'
          parse_list_models_response(nil, slug, Perplexity::Capabilities)
        end

        def parse_list_models_response(_response, slug, capabilities)
          MODEL_IDS.map { |id| create_model_info(id, slug, capabilities) }
        end

        def create_model_info(id, slug, capabilities)
          Model::Info.new(
            id: id,
            name: id,
            provider: slug,
            context_window: capabilities.context_window_for(id),
            max_output_tokens: capabilities.max_tokens_for(id),
            capabilities: capabilities.critical_capabilities_for(id),
            pricing: capabilities.pricing_for(id),
            metadata: {}
          )
        end
      end
    end
  end
end
