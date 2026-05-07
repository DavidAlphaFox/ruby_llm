# frozen_string_literal: true

require 'active_support/concern'
require 'ruby_llm/active_record/payload_helpers'

module RubyLLM
  module ActiveRecord
    # Methods mixed into message models.
    #
    # `acts_as_message` 注入到 Message AR 类的方法。
    #
    # 把数据库行还原为 {RubyLLM::Message}（{#to_llm}），同时提供：
    # - {#thinking} / {#tokens} / {#cost} 派生属性
    # - {#to_partial_path} —— Rails 视图局部模板的智能路径
    # - 对 ActiveStorage 附件的下载与 Tempfile 包装
    module MessageMethods
      extend ActiveSupport::Concern
      include PayloadHelpers

      class_methods do
        attr_reader :chat_class, :tool_call_class, :chat_foreign_key, :tool_call_foreign_key
      end

      # AR 行 → RubyLLM::Message。
      def to_llm
        RubyLLM::Message.new(
          role: role.to_sym,
          content: extract_content,
          thinking: thinking,
          tokens: tokens,
          tool_calls: extract_tool_calls,
          tool_call_id: extract_tool_call_id,
          model_id: model_association&.model_id
        )
      end

      # 从 thinking_text + thinking_signature 列构造 Thinking 对象。
      def thinking
        RubyLLM::Thinking.build(
          text: thinking_text_value,
          signature: thinking_signature_value
        )
      end

      # 从 token 计数列构造 Tokens 对象。
      def tokens
        RubyLLM::Tokens.build(
          input: input_tokens,
          output: output_tokens,
          cached: cached_value,
          cache_creation: cache_creation_value,
          thinking: thinking_tokens_value
        )
      end

      # 该消息的费用。
      def cost
        RubyLLM::Cost.new(tokens:, model: model_association)
      end

      # @return [Integer, nil] cached 列的别名
      def cache_read_tokens = cached_value
      # @return [Integer, nil] cache_creation 列的别名
      def cache_write_tokens = cache_creation_value

      # Rails 视图渲染辅助：根据角色返回不同的 partial 路径。
      # 如 `messages/user`、`messages/assistant`、`messages/tool_calls`、
      # `messages/tool`，便于 chat_ui generator 生成的 UI 直接 render @messages。
      def to_partial_path
        partial_prefix = self.class.name.underscore.pluralize
        role_partial = if to_llm.tool_call?
                         'tool_calls'
                       elsif role.to_s == 'tool'
                         'tool'
                       else
                         role.to_s.presence || 'assistant'
                       end
        "#{partial_prefix}/#{role_partial}"
      end

      # 工具结果消息的错误描述（content 列里 JSON 的 `error` 字段）。
      def tool_error_message
        payload_error_message(content)
      end

      private

      def thinking_text_value
        has_attribute?(:thinking_text) ? self[:thinking_text] : nil
      end

      def thinking_signature_value
        has_attribute?(:thinking_signature) ? self[:thinking_signature] : nil
      end

      def cached_value
        has_attribute?(:cached_tokens) ? self[:cached_tokens] : nil
      end

      def cache_creation_value
        has_attribute?(:cache_creation_tokens) ? self[:cache_creation_tokens] : nil
      end

      def thinking_tokens_value
        has_attribute?(:thinking_tokens) ? self[:thinking_tokens] : nil
      end

      # 把 has_many tool_calls 关联展开为 {tool_call_id => ToolCall} hash。
      def extract_tool_calls
        tool_calls_association.to_h do |tool_call|
          [
            tool_call.tool_call_id,
            RubyLLM::ToolCall.new(
              id: tool_call.tool_call_id,
              name: tool_call.name,
              arguments: tool_call.arguments,
              thought_signature: tool_call.try(:thought_signature)
            )
          ]
        end
      end

      # 工具结果消息会通过 parent_tool_call 关联到触发它的 tool_call 行。
      def extract_tool_call_id
        parent_tool_call&.tool_call_id
      end

      # 综合 content 列、ActionText、ActiveStorage 附件构造 Content 对象。
      #
      # 优先级：
      # 1. `content_raw` 列（Raw payload）—— 原样作为 Content::Raw
      # 2. ActionText 富文本 —— 通过 `to_plain_text` 转字符串
      # 3. 普通字符串 + 无附件 —— 直接返回字符串
      # 4. 普通字符串 + 有 ActiveStorage 附件 —— 把每个附件下载到 Tempfile
      #    再 add_attachment（保留在 `@_tempfiles` 里防止 GC）
      def extract_content
        return RubyLLM::Content::Raw.new(content_raw) if has_attribute?(:content_raw) && content_raw.present?

        content_value = content
        content_value = content_value.to_plain_text if content_value.respond_to?(:to_plain_text)

        return content_value unless respond_to?(:attachments) && attachments.attached?

        RubyLLM::Content.new(content_value).tap do |content_obj|
          @_tempfiles = []

          attachments.each do |attachment|
            tempfile = download_attachment(attachment)
            content_obj.add_attachment(tempfile, filename: attachment.filename.to_s)
          end
        end
      end

      # 把 ActiveStorage 附件流式下载到 Tempfile（保留扩展名，便于
      # MIME 类型探测）。Tempfile 实例由 `@_tempfiles` 持有以延长生命周期。
      def download_attachment(attachment)
        ext = File.extname(attachment.filename.to_s)
        basename = File.basename(attachment.filename.to_s, ext)
        tempfile = Tempfile.new([basename, ext])
        tempfile.binmode

        attachment.download { |chunk| tempfile.write(chunk) }

        tempfile.flush
        tempfile.rewind
        @_tempfiles << tempfile
        tempfile
      end
    end
  end
end
