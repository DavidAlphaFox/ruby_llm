# frozen_string_literal: true

require 'pathname'
require 'uri'

module RubyLLM
  # A class representing a file attachment.
  #
  # 文件附件抽象。
  #
  # 把多种"附件来源"统一为一个对象，屏蔽底层差异：
  # - **本地路径**：String / Pathname
  # - **URL**：http(s) 字符串或 URI
  # - **IO 对象**：File / StringIO / ActionDispatch::Http::UploadedFile
  # - **ActiveStorage**：Blob / Attachment / Attached::One / Attached::Many
  #
  # 提供：MIME 类型自动检测（基于 Marcel）、内容懒加载、base64 编码、
  # 类型判定（image?/video?/audio?/pdf?/text?）、序列化、`for_llm` 拼装
  # （文本类用 `<file>` 标签包裹；二进制类用 `data:` URI）。
  class Attachment
    # @return [URI, Pathname, IO, ActiveStorage::*, Object] 已类型转换后的来源
    # @return [String] 文件名（用于日志、provider 协议）
    # @return [String] MIME 类型（如 `'image/png'`）
    attr_reader :source, :filename, :mime_type

    # @param source [String, URI, Pathname, IO, ActiveStorage::*]
    # @param filename [String, nil] 显式文件名；缺省时从 source 推断
    def initialize(source, filename: nil)
      @source = source
      @source = source_type_cast
      @filename = filename || source_filename

      determine_mime_type
    end

    # 是否是 URL 来源。
    def url?
      @source.is_a?(URI) || (@source.is_a?(String) && @source.match?(%r{^https?://}))
    end

    # 是否是本地路径。
    def path?
      @source.is_a?(Pathname) || (@source.is_a?(String) && !url?)
    end

    # 是否是 IO 类对象（响应 `read` 但不是路径/AS Blob）。
    def io_like?
      @source.respond_to?(:read) && !path? && !active_storage?
    end

    # 是否是 ActiveStorage 对象（支持 Blob / Attachment / Attached::One/Many）。
    def active_storage?
      return false unless defined?(ActiveStorage)

      @source.is_a?(ActiveStorage::Blob) ||
        @source.is_a?(ActiveStorage::Attachment) ||
        @source.is_a?(ActiveStorage::Attached::One) ||
        @source.is_a?(ActiveStorage::Attached::Many)
    end

    # 懒加载并缓存附件内容。
    # 不同来源走不同读取路径；无法识别时打 warn 并返回 nil。
    #
    # @return [String, nil] 二进制内容
    def content
      return @content if defined?(@content) && !@content.nil?

      if url?
        fetch_content
      elsif path?
        load_content_from_path
      elsif active_storage?
        load_content_from_active_storage
      elsif io_like?
        load_content_from_io
      else
        RubyLLM.logger.warn "Source is neither a URL, path, ActiveStorage, nor IO-like: #{@source.class}"
        nil
      end

      @content
    end

    # base64 字符串（无换行的 strict 形式，适合 data URI）。
    def encoded
      Base64.strict_encode64(content)
    end

    # 把 IO 类来源持久化到磁盘。
    #
    # @param path [String]
    def save(path)
      return unless io_like?

      File.open(path, 'w') do |f|
        f.puts(@source.read)
      end
    end

    # 拼装可直接嵌入到模型上下文的字符串：
    # 文本文件用 `<file>` 标签 + 原文；其他类型用 base64 data URI。
    def for_llm
      case type
      when :text
        "<file name='#{filename}' mime_type='#{mime_type}'>#{content}</file>"
      else
        "data:#{mime_type};base64,#{encoded}"
      end
    end

    # 推断附件粗类型：`:image / :video / :audio / :pdf / :text / :unknown`。
    def type
      return :image if image?
      return :video if video?
      return :audio if audio?
      return :pdf if pdf?
      return :text if text?

      :unknown
    end

    # @return [Boolean]
    def image? = RubyLLM::MimeType.image?(mime_type)
    # @return [Boolean]
    def video? = RubyLLM::MimeType.video?(mime_type)
    # @return [Boolean]
    def audio? = RubyLLM::MimeType.audio?(mime_type)

    # 转为 provider 期望的简短格式后缀（如 `'mp3'`/`'wav'`/`'png'`）。
    def format
      case mime_type
      when 'audio/mpeg'
        'mp3'
      when 'audio/wav', 'audio/wave', 'audio/x-wav'
        'wav'
      else
        mime_type.split('/').last
      end
    end

    # @return [Boolean]
    def pdf? = RubyLLM::MimeType.pdf?(mime_type)
    # @return [Boolean]
    def text? = RubyLLM::MimeType.text?(mime_type)

    # 序列化为 hash（用于持久化）。
    def to_h
      { type: type, source: @source }
    end

    private

    # 决定 MIME 类型：
    # - ActiveStorage：直接用 blob 的 content_type
    # - URL：通过文件名后缀猜测；若得到 octet-stream 再下载内容嗅探
    # - 路径/IO：先按文件名猜，再按内容嗅探
    # 最后做 audio/x-wav → audio/wav 的归一化。
    def determine_mime_type
      return @mime_type = active_storage_content_type if active_storage? && active_storage_content_type.present?

      @mime_type = RubyLLM::MimeType.for(url? ? nil : @source, name: @filename)
      @mime_type = RubyLLM::MimeType.for(content) if @mime_type == 'application/octet-stream'
      @mime_type = 'audio/wav' if @mime_type == 'audio/x-wav' # Normalize WAV type
    end

    def fetch_content
      response = Connection.basic.get @source.to_s
      @content = response.body
    end

    def load_content_from_path
      @content = File.binread(@source)
    end

    def load_content_from_io
      @source.rewind if @source.respond_to? :rewind
      @content = @source.read
    end

    def load_content_from_active_storage
      return unless defined?(ActiveStorage)

      @content = active_storage_blob&.download
    end

    def source_type_cast
      if url?
        URI(@source)
      elsif path?
        Pathname.new(@source)
      else
        @source
      end
    end

    def source_filename
      if url?
        File.basename(@source.path).to_s
      elsif path?
        @source.basename.to_s
      elsif io_like?
        extract_filename_from_io
      elsif active_storage?
        extract_filename_from_active_storage
      end
    end

    def extract_filename_from_io
      if defined?(ActionDispatch::Http::UploadedFile) && @source.is_a?(ActionDispatch::Http::UploadedFile)
        @source.original_filename.to_s
      elsif @source.respond_to?(:path)
        File.basename(@source.path).to_s
      else
        'attachment'
      end
    end

    def extract_filename_from_active_storage
      return 'attachment' unless defined?(ActiveStorage)

      active_storage_blob&.filename&.to_s || 'attachment'
    end

    def active_storage_content_type
      return unless defined?(ActiveStorage)

      active_storage_blob&.content_type
    end

    def active_storage_blob
      case @source
      when ActiveStorage::Blob then @source
      when ActiveStorage::Attachment, ActiveStorage::Attached::One then @source.blob
      when ActiveStorage::Attached::Many then @source.blobs.first
      end
    end
  end
end
