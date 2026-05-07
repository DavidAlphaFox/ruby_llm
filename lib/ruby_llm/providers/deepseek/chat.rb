# frozen_string_literal: true

module RubyLLM
  module Providers
    class DeepSeek
      # Chat methods of the DeepSeek API integration
      #
      # DeepSeek 协议与 OpenAI 几乎一致，仅覆盖 `format_role` —— 不做
      # `:system → 'developer'` 的翻译（DeepSeek 用 `'system'`）。
      # 其他逻辑全部继承 OpenAI::Chat。
      module Chat
        module_function

        def format_role(role) = role.to_s
      end
    end
  end
end
