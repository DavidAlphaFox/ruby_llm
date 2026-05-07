# frozen_string_literal: true

module RubyLLM
  module Providers
    class Azure
      # Chat methods of the Azure AI Foundry API integration
      #
      # 与 OpenAI 协议相同，仅有两处差异：
      # - 端点 URL 走 {Azure#azure_endpoint(:chat)} 动态拼装
      # - role 始终保留 `'system'`（不强制翻译为 'developer'，因为
      #   Azure 部署可能使用任意底层模型）
      module Chat
        def completion_url
          azure_endpoint(:chat)
        end

        def format_messages(messages)
          messages.map do |msg|
            {
              role: format_role(msg.role),
              content: Media.format_content(msg.content),
              tool_calls: format_tool_calls(msg.tool_calls),
              tool_call_id: msg.tool_call_id
            }.compact.merge(format_thinking(msg))
          end
        end

        # Azure 不做 system→developer 翻译。
        def format_role(role)
          role.to_s
        end
      end
    end
  end
end
