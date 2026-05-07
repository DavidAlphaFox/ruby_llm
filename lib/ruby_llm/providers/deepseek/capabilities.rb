# frozen_string_literal: true

module RubyLLM
  module Providers
    class DeepSeek
      # Provider-level capability checks used outside the model registry.
      #
      # DeepSeek 支持 tool_choice 字段，但不支持并行工具调用控制。
      module Capabilities
        module_function

        def supports_tool_choice?(_model_id) = true
        def supports_tool_parallel_control?(_model_id) = false
      end
    end
  end
end
