# frozen_string_literal: true

module RubyLLM
  module Providers
    class Anthropic
      # Provider-level capability checks used outside the model registry.
      #
      # Anthropic 所有当前在线的 Claude 模型都支持工具选择与并行工具
      # 调用，因此两个谓词恒为 true（保留方法签名以保持与其他 provider
      # 的一致接口）。
      module Capabilities
        module_function

        def supports_tool_choice?(_model_id) = true
        def supports_tool_parallel_control?(_model_id) = true
      end
    end
  end
end
