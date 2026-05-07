# frozen_string_literal: true

module RubyLLM
  # Represents the content sent to or received from an LLM.
  #
  # 消息内容容器 —— 文本 + 任意多个附件的统一封装。
  #
  # `Chat#ask(message, with: ...)` 会把用户输入与 `with:` 附件参数交给
  # `Content.new`，统一成 `Content` 实例。各 provider 的 `Media` mixin
  # 会读取 `text` 和 `attachments` 并按 provider 协议拼装最终消息。
  class Content
    # @return [String, nil] 文本部分
    # @return [Array<RubyLLM::Attachment>] 附件列表
    attr_reader :text, :attachments

    # @param text [String, nil] 文本
    # @param attachments [String, Array<String>, Hash, nil] 附件来源；
    #   - 字符串：单个文件路径或 URL
    #   - 数组：多个文件路径
    #   - hash：按类型分组（如 `{image: '...', pdf: '...'}`）
    # @raise [ArgumentError] 当 text 与 attachments 都为空时
    def initialize(text = nil, attachments = nil)
      @text = text
      @attachments = []

      process_attachments(attachments)
      raise ArgumentError, 'Text and attachments cannot be both nil' if @text.nil? && @attachments.empty?
    end

    # 追加一个附件。
    #
    # @param source [String, URI, Pathname, IO, ActiveStorage::Blob, ...]
    # @param filename [String, nil]
    # @return [self]
    def add_attachment(source, filename: nil)
      @attachments << Attachment.new(source, filename:)
      self
    end

    # 用于发送时的"格式化"判断：仅含文本无附件时直接返回字符串，
    # 否则返回自身（让 provider Media mixin 进一步处理）。
    def format
      if @text && @attachments.empty?
        @text
      else
        self
      end
    end

    # For Rails serialization
    #
    # 序列化为 hash —— 用于 Rails ActiveRecord 持久化。
    def to_h
      { text: @text, attachments: @attachments.map(&:to_h) }
    end

    private

    # 把单个/数组形态的附件输入规范化为 Attachment 列表。
    def process_attachments_array_or_string(attachments)
      Utils.to_safe_array(attachments).each do |file|
        next if blank_attachment_entry?(file)

        add_attachment(file)
      end
    end

    def blank_attachment_entry?(file)
      file.nil? || (file.is_a?(String) && file.strip.empty?)
    end

    # 入口：根据用户传入的形态分派（Hash 形式按类型 key 展开）。
    def process_attachments(attachments)
      if attachments.is_a?(Hash)
        attachments.each_value { |attachment| process_attachments_array_or_string(attachment) }
      else
        process_attachments_array_or_string attachments
      end
    end
  end

  class Content
    # Represents provider-specific payloads that should bypass RubyLLM formatting.
    #
    # 原生（"逃生舱"）payload 容器。
    #
    # 当用户需要绕开 RubyLLM 的统一格式化、直接传入某 provider 的
    # 原生消息结构时，可以用 `Content::Raw.new(payload)` 包裹；
    # provider 的 Media mixin 见到 Raw 就直接把 `.value` 写入请求。
    class Raw
      # @return [Object] 原始 payload（任何 provider 期望的结构）
      attr_reader :value

      # @raise [ArgumentError] value 不能为 nil
      def initialize(value)
        raise ArgumentError, 'Raw content payload cannot be nil' if value.nil?

        @value = value
      end

      def format
        @value
      end

      def to_h
        @value
      end
    end
  end
end
