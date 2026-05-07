# frozen_string_literal: true

module RubyLLM
  module Providers
    class GPUStack
      # Determines capabilities for GPUStack models
      #
      # GPUStack 模型 backends 各异（vLLM / Ollama / llama.cpp 等），
      # 工具相关高级特性统一不开启，避免误用。
      module Capabilities
        module_function

        def supports_tool_choice?(_model_id) = false
        def supports_tool_parallel_control?(_model_id) = false
      end
    end
  end
end
