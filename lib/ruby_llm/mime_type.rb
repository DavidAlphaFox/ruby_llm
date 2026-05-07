# frozen_string_literal: true

require 'marcel'

module RubyLLM
  # MimeTypes module provides methods to handle MIME types using Marcel gem
  #
  # MIME 类型判定工具。
  #
  # 在 `Marcel::MimeType.for` 之上提供更高层的"是否文本/图像/视频/
  # 音频/PDF"判定。{text?} 的逻辑相对复杂，因为不少应用层 MIME
  # 类型实际上是文本（JSON、YAML、XML、JS 源码等），但前缀是
  # `application/` —— 需要额外白名单与后缀匹配兜底。
  module MimeType
    module_function

    # 透传 Marcel 的 MIME 探测（按文件名/内容/path 综合判定）。
    # @return [String]
    def for(...)
      Marcel::MimeType.for(...)
    end

    # @param type [String]
    # @return [Boolean]
    def image?(type) = type.start_with?('image/')
    # @return [Boolean]
    def video?(type) = type.start_with?('video/')
    # @return [Boolean]
    def audio?(type) = type.start_with?('audio/')
    # @return [Boolean]
    def pdf?(type)   = type == 'application/pdf'

    # 文本判定 —— 三个条件任一满足即视为文本：
    # 1. 以 `text/` 开头
    # 2. 以已知"文本派生"后缀结尾（`+json`、`+xml`、`+yaml` 等）
    # 3. 命中 NON_TEXT_PREFIX_TEXT_MIME_TYPES 白名单
    def text?(type)
      type.start_with?('text/') ||
        TEXT_SUFFIXES.any? { |suffix| type.end_with?(suffix) } ||
        NON_TEXT_PREFIX_TEXT_MIME_TYPES.include?(type)
    end

    # MIME types that have a text/ prefix but need to be handled differently
    TEXT_SUFFIXES = ['+json', '+xml', '+html', '+yaml', '+csv', '+plain', '+javascript', '+svg'].freeze

    # MIME types that don't have a text/ prefix but should be treated as text
    NON_TEXT_PREFIX_TEXT_MIME_TYPES = [
      'application/json', # Base type, even if specific ones end with +json
      'application/xml',  # Base type, even if specific ones end with +xml
      'application/javascript',
      'application/ecmascript',
      'application/rtf',
      'application/sql',
      'application/x-sh',
      'application/x-csh',
      'application/x-httpd-php',
      'application/sdp',
      'application/sparql-query',
      'application/graphql',
      'application/yang', # Data modeling language, often serialized as XML/JSON but the type itself is distinct
      'application/mbox', # Mailbox format
      'application/x-tex',
      'application/x-latex',
      'application/x-perl',
      'application/x-python',
      'application/x-tcl',
      'application/pgp-signature', # Often ASCII armored
      'application/pgp-keys',      # Often ASCII armored
      'application/vnd.coffeescript',
      'application/vnd.dart',
      'application/vnd.oai.openapi', # Base for OpenAPI, often with +json or +yaml suffix
      'application/vnd.zul',         # ZK User Interface Language (can be XML-like)
      'application/x-yaml',          # Common non-standard for YAML
      'application/yaml',            # Standard for YAML
      'application/toml'             # TOML configuration files
    ].freeze
  end
end
