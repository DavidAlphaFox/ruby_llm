# frozen_string_literal: true

module RubyLLM
  module Providers
    # GPUStack API integration based on Ollama.
    #
    # GPUStack（自托管 GPU 集群）提供 OpenAI 兼容 API。被标记为
    # `local?` 以跳过模型注册表的严格校验（用户私有模型可直接使用）。
    class GPUStack < OpenAI
      include GPUStack::Chat
      include GPUStack::Models
      include GPUStack::Media

      def api_base
        @config.gpustack_api_base
      end

      def headers
        return {} unless @config.gpustack_api_key

        {
          'Authorization' => "Bearer #{@config.gpustack_api_key}"
        }
      end

      class << self
        def configuration_options
          %i[gpustack_api_base gpustack_api_key]
        end

        def local?
          true
        end

        def configuration_requirements
          %i[gpustack_api_base]
        end

        def capabilities
          GPUStack::Capabilities
        end
      end
    end
  end
end
