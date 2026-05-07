# frozen_string_literal: true

module RubyLLM
  module Providers
    class Perplexity
      # Chat formatting for Perplexity provider
      #
      # 协议兼容 OpenAI；唯一覆盖：保留 `'system'` role（不翻译为 'developer'）。
      # 其余补全/解析逻辑全部继承 OpenAI::Chat。
      module Chat
        module_function

        def format_role(role) = role.to_s
      end
    end
  end
end
