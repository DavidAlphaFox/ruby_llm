# frozen_string_literal: true

module RubyLLM
  module Providers
    class Azure
      # Models methods of the Azure AI Foundry API integration
      #
      # 仅覆盖 URL（走 {Azure#azure_endpoint(:models)}），响应格式
      # 与 OpenAI `/v1/models` 相同，因此 parse 复用父类。
      module Models
        def models_url
          azure_endpoint(:models)
        end
      end
    end
  end
end
