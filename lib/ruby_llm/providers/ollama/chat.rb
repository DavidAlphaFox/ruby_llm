# frozen_string_literal: true

module RubyLLM
  module Providers
    class Ollama
      # Chat methods of the Ollama API integration
      #
      # 使用 OpenAI 兼容协议；本地服务，不强制 system→developer 翻译。
      # 媒体附件走 Ollama::Media（仅支持 image/text）。
      module Chat
        module_function

        def format_messages(messages)
          messages.map do |msg|
            {
              role: format_role(msg.role),
              content: Ollama::Media.format_content(msg.content),
              tool_calls: format_tool_calls(msg.tool_calls),
              tool_call_id: msg.tool_call_id
            }.compact.merge(OpenAI::Chat.format_thinking(msg))
          end
        end

        def format_role(role)
          role.to_s
        end
      end
    end
  end
end
