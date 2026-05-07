# frozen_string_literal: true

module RubyLLM
  module Providers
    class XAI
      # Chat implementation for xAI
      # https://docs.x.ai/docs/api-reference#chat-completions
      #
      # xAI（Grok 系列）OpenAI 兼容协议；仅覆盖 format_role 保留
      # `'system'` 字面量（不翻译为 'developer'）。
      module Chat
        def format_role(role) = role.to_s
      end
    end
  end
end
