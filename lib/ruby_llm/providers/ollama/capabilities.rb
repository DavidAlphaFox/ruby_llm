# frozen_string_literal: true

module RubyLLM
  module Providers
    class Ollama
      # Determines capabilities for Ollama models
      #
      # Ollama 是本地推理服务，不同模型对工具控制的支持差异很大；
      # 出于安全保守考虑，统一关闭高级工具特性（用户可在 chat 层
      # 通过 `with_params` 强制覆盖）。
      module Capabilities
        module_function

        def supports_tool_choice?(_model_id) = false
        def supports_tool_parallel_control?(_model_id) = false
      end
    end
  end
end
