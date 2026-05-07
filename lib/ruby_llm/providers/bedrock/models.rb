# frozen_string_literal: true

module RubyLLM
  module Providers
    class Bedrock
      # Models methods for AWS Bedrock.
      #
      # Bedrock 模型 ID 有"区域前缀"概念（cross-region inference profile）：
      # 同一基础模型在不同区域有 `us.`、`eu.`、`ap.` 等前缀的版本。
      # 本模块负责：
      # - 列出 `/foundation-models` 与 `/inference-profiles`
      # - 根据当前 region 解析模型 ID 的正确前缀（{Models.with_region_prefix}）
      # - 对支持的模型自动启用 inference profile
      module Models
        module_function

        # AWS Bedrock 支持的区域前缀（用于 cross-region inference profile）。
        REGION_PREFIXES = %w[global us eu ap sa ca me af il].freeze

        def models_api_base
          "https://bedrock.#{bedrock_region}.amazonaws.com"
        end

        def models_url
          '/foundation-models'
        end

        def parse_list_models_response(response, slug, _capabilities)
          Array(response.body['modelSummaries']).map do |model_data|
            create_model_info(model_data, slug)
          end
        end

        def create_model_info(model_data, slug, _capabilities = nil)
          model_id = model_id_with_region(model_data['modelId'], model_data)
          converse_data = model_data['converse'] || {}

          Model::Info.new(
            id: model_id,
            name: model_data['modelName'],
            provider: slug,
            family: model_data['modelFamily'] || model_data['providerName']&.downcase,
            created_at: nil,
            context_window: parse_context_window(model_data),
            max_output_tokens: converse_data['maxTokensDefault'] || converse_data['maxTokensMaximum'],
            modalities: {
              input: normalize_modalities(model_data['inputModalities']),
              output: normalize_modalities(model_data['outputModalities'])
            },
            capabilities: parse_capabilities(model_data),
            pricing: {},
            metadata: {
              provider_name: model_data['providerName'],
              model_arn: model_data['modelArn'],
              inference_types: model_data['inferenceTypesSupported'],
              converse: converse_data
            }
          )
        end

        def model_id_with_region(model_id, model_data)
          inference_types = Array(model_data['inferenceTypesSupported'])
          normalize_inference_profile_id(model_id, inference_types, @config.bedrock_region)
        end

        def normalize_inference_profile_id(model_id, inference_types, region)
          return model_id unless inference_types.include?('INFERENCE_PROFILE')
          return model_id if inference_types.include?('ON_DEMAND')

          with_region_prefix(model_id, region)
        end

        def with_region_prefix(model_id, region)
          prefix = region_prefix(region)

          if region_prefixed?(model_id)
            model_id.sub(/\A(?:#{REGION_PREFIXES.join('|')})\./, "#{prefix}.")
          else
            "#{prefix}.#{model_id}"
          end
        end

        def region_prefix(region)
          prefix = region.to_s.split('-').first
          prefix = '' if prefix.nil?
          prefix.empty? ? 'us' : prefix
        end

        def region_prefixed?(model_id)
          model_id.match?(/\A(?:#{REGION_PREFIXES.join('|')})\./)
        end

        def normalize_modalities(modalities)
          Array(modalities).map do |modality|
            normalized = modality.to_s.downcase
            case normalized
            when 'embedding' then 'embeddings'
            when 'speech' then 'audio'
            else normalized
            end
          end
        end

        def parse_capabilities(model_data)
          capabilities = []
          capabilities << 'streaming' if model_data['responseStreamingSupported']

          converse = model_data['converse'] || {}
          capabilities << 'function_calling' if converse.is_a?(Hash)
          capabilities << 'reasoning' if converse.dig('reasoningSupported', 'embedded')
          capabilities << 'structured_output' if supports_structured_output?(model_data['modelId'])

          capabilities
        end

        # Structured output supported on Claude 4.5+ and assumed for future major versions.
        # Bedrock IDs look like: us.anthropic.claude-haiku-4-5-20251001-v1:0
        # Must handle optional region prefix (us./eu./global.) and anthropic. prefix.
        def supports_structured_output?(model_id)
          return false unless model_id

          normalized = model_id.sub(/\A(?:#{REGION_PREFIXES.join('|')})\./, '').delete_prefix('anthropic.')
          match = normalized.match(/claude-(?:opus|sonnet|haiku)-(\d+)-(\d{1,2})(?:\b|-)/)
          return false unless match

          major = match[1].to_i
          minor = match[2].to_i
          major > 4 || (major == 4 && minor >= 5)
        end

        def reasoning_embedded?(model)
          metadata = RubyLLM::Utils.deep_symbolize_keys(model.metadata || {})
          converse = metadata[:converse] || {}
          reasoning_supported = converse[:reasoningSupported] || {}
          reasoning_supported[:embedded] || false
        end

        def parse_context_window(model_data)
          value = model_data.dig('description', 'maxContextWindow')
          return unless value.is_a?(String)

          if value.match?(/\A\d+[kK]\z/)
            value.to_i * 1000
          elsif value.match?(/\A\d+\z/)
            value.to_i
          end
        end
      end
    end
  end
end
