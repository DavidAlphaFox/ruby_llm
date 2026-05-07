# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Handles formatting of media content (images, audio) for OpenAI APIs
      #
      # 把 `Content`（文本 + 多附件）翻译成 OpenAI 的 `content` 数组格式：
      # - 文本块：`{type: 'text', text: ...}`
      # - 图像：`{type: 'image_url', image_url: {url: ...}}`（URL 或 data URI）
      # - PDF：`{type: 'file', file: {filename, file_data}}`（gpt-4o 等支持）
      # - 音频：`{type: 'input_audio', input_audio: {data, format}}`
      # - 文本文件：`{type: 'text', text: <file>...</file>}` 包裹后嵌入
      # - {Content::Raw}：直接传 value（用户自己负责格式正确）
      module Media
        module_function

        # 入口：根据 content 形态分派。
        # 未识别的附件类型抛 {UnsupportedAttachmentError}。
        def format_content(content) # rubocop:disable Metrics/PerceivedComplexity
          if content.is_a?(RubyLLM::Content::Raw)
            value = content.value
            return value.is_a?(Hash) ? value.to_json : value
          end
          return content.to_json if content.is_a?(Hash) || content.is_a?(Array)
          return content unless content.is_a?(Content)

          parts = []
          parts << format_text(content.text) if content.text

          content.attachments.each do |attachment|
            case attachment.type
            when :image
              parts << format_image(attachment)
            when :pdf
              parts << format_pdf(attachment)
            when :audio
              parts << format_audio(attachment)
            when :text
              parts << format_text_file(attachment)
            else
              raise UnsupportedAttachmentError, attachment.type
            end
          end

          parts
        end

        def format_image(image)
          {
            type: 'image_url',
            image_url: {
              url: image.url? ? image.source.to_s : image.for_llm
            }
          }
        end

        def format_pdf(pdf)
          {
            type: 'file',
            file: {
              filename: pdf.filename,
              file_data: pdf.for_llm
            }
          }
        end

        def format_text_file(text_file)
          {
            type: 'text',
            text: text_file.for_llm
          }
        end

        def format_audio(audio)
          {
            type: 'input_audio',
            input_audio: {
              data: audio.encoded,
              format: audio.format
            }
          }
        end

        def format_text(text)
          {
            type: 'text',
            text: text
          }
        end
      end
    end
  end
end
