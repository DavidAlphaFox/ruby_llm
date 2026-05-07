# frozen_string_literal: true

require 'active_support/concern'
require 'ruby_llm/active_record/payload_helpers'

module RubyLLM
  module ActiveRecord
    # Methods mixed into tool call models.
    #
    # `acts_as_tool_call` 自动 include 进 ToolCall AR 模型的方法。
    # 目前只有一个：从 arguments 列里提取 error 文本。
    module ToolCallMethods
      extend ActiveSupport::Concern
      include PayloadHelpers

      # 若工具调用失败，从 arguments payload 中抽出错误描述。
      # @return [String, nil]
      def tool_error_message
        payload_error_message(arguments)
      end
    end
  end
end
