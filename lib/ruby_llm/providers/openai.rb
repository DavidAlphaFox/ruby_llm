# frozen_string_literal: true

module RubyLLM
  module Providers
    # OpenAI API integration.
    #
    # OpenAI 是 RubyLLM 中"最完整的"provider —— 实现了几乎所有能力：
    # chat、embeddings、images、moderation、transcription、tools、
    # streaming、media、structured output。
    #
    # 多家"OpenAI 兼容"的 provider（Azure、DeepSeek、GPUStack、Mistral、
    # Ollama、OpenRouter、Perplexity、xAI）继承自本类并仅覆盖必要方法。
    class OpenAI < Provider
      include OpenAI::Chat
      include OpenAI::Embeddings
      include OpenAI::Models
      include OpenAI::Moderation
      include OpenAI::Streaming
      include OpenAI::Tools
      include OpenAI::Images
      include OpenAI::Media
      include OpenAI::Transcription

      # OpenAI v1 API 根地址；可通过 `openai_api_base` 配置覆盖
      # （兼容 OpenAI 兼容代理）。
      def api_base
        @config.openai_api_base || 'https://api.openai.com/v1'
      end

      # 认证头 + 可选的组织/项目 ID（compact 去 nil）。
      def headers
        {
          'Authorization' => "Bearer #{@config.openai_api_key}",
          'OpenAI-Organization' => @config.openai_organization_id,
          'OpenAI-Project' => @config.openai_project_id
        }.compact
      end

      # OpenAI o-系列推理模型不接受任意温度（必须为 1.0），这里委托给
      # {OpenAI::Temperature} 做归一化。
      def maybe_normalize_temperature(temperature, model)
        OpenAI::Temperature.normalize(temperature, model.id)
      end

      class << self
        def capabilities
          OpenAI::Capabilities
        end

        def configuration_options
          %i[
            openai_api_key
            openai_api_base
            openai_organization_id
            openai_project_id
            openai_use_system_role
          ]
        end

        def configuration_requirements
          %i[openai_api_key]
        end
      end
    end
  end
end
