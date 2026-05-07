# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Audio transcription methods for the OpenAI API integration
      #
      # OpenAI `/v1/audio/transcriptions` 协议实现，支持 Whisper 与
      # gpt-4o-(*)-transcribe 系列。可选 chunking_strategy（仅
      # diarize 模型）、timestamp_granularities、说话人识别（speaker
      # references 编码为 base64 data URI）。
      module Transcription
        module_function

        def transcription_url
          'audio/transcriptions'
        end

        def render_transcription_payload(file_part, model:, language:, **options)
          {
            model: model,
            file: file_part,
            language: language,
            chunking_strategy: (options[:chunking_strategy] || 'auto' if supports_chunking_strategy?(model, options)),
            response_format: response_format_for(model, options),
            prompt: options[:prompt],
            temperature: options[:temperature],
            timestamp_granularities: options[:timestamp_granularities],
            known_speaker_names: options[:speaker_names],
            known_speaker_references: encode_speaker_references(options[:speaker_references])
          }.compact
        end

        def encode_speaker_references(references)
          return nil unless references

          references.map do |ref|
            Attachment.new(ref).for_llm
          end
        end

        def response_format_for(model, options)
          return options[:response_format] if options.key?(:response_format)

          'diarized_json' if model.include?('diarize')
        end

        def supports_chunking_strategy?(model, options)
          return false if model.start_with?('whisper')
          return true if options.key?(:chunking_strategy)

          model.include?('diarize')
        end

        def parse_transcription_response(response, model:)
          data = response.body

          return RubyLLM::Transcription.new(text: data, model: model) if data.is_a?(String)

          usage = data['usage'] || {}

          RubyLLM::Transcription.new(
            text: data['text'],
            model: model,
            language: data['language'],
            duration: data['duration'],
            segments: data['segments'],
            input_tokens: usage['input_tokens'] || usage['prompt_tokens'],
            output_tokens: usage['output_tokens'] || usage['completion_tokens']
          )
        end
      end
    end
  end
end
