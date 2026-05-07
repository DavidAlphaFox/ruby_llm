# frozen_string_literal: true

module RubyLLM
  module Providers
    class GPUStack
      # Handles formatting of media content (images, audio) for GPUStack APIs
      #
      # 仅支持 image 与 text 文件附件；其他类型（PDF/audio/video）
      # 抛 UnsupportedAttachmentError。`format_image` 中显式带
      # `detail: 'auto'`（部分 vLLM 后端要求）。
      module Media
        extend OpenAI::Media

        module_function

        def format_content(content)
          return content.value if content.is_a?(RubyLLM::Content::Raw)
          return content.to_json if content.is_a?(Hash) || content.is_a?(Array)
          return content unless content.is_a?(Content)

          parts = []
          parts << format_text(content.text) if content.text

          content.attachments.each do |attachment|
            case attachment.type
            when :image
              parts << GPUStack::Media.format_image(attachment)
            when :text
              parts << format_text_file(attachment)
            else
              raise UnsupportedAttachmentError, attachment.mime_type
            end
          end

          parts
        end

        def format_image(image)
          {
            type: 'image_url',
            image_url: {
              url: image.for_llm,
              detail: 'auto'
            }
          }
        end
      end
    end
  end
end
