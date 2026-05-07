# frozen_string_literal: true

module RubyLLM
  # Represents a transcription of audio content.
  #
  # 音频转写结果。
  #
  # 不同 provider 返回的字段细节略有差异：OpenAI Whisper 给出
  # `text + segments + duration + language`；Gemini 仅返回 `text`。
  # 本类把所有可用字段都暴露为可选属性。
  class Transcription
    # @return [String] 转写后的纯文本
    # @return [String] 使用的模型 ID
    # @return [String, nil] 检测/指定的语言代码
    # @return [Float, nil] 音频时长（秒）
    # @return [Array<Hash>, nil] 分段（含起止时间、置信度等）
    # @return [Integer, nil] 输入 token
    # @return [Integer, nil] 输出 token
    attr_reader :text, :model, :language, :duration, :segments, :input_tokens, :output_tokens

    def initialize(text:, model:, **attributes)
      @text = text
      @model = model
      @language = attributes[:language]
      @duration = attributes[:duration]
      @segments = attributes[:segments]
      @input_tokens = attributes[:input_tokens]
      @output_tokens = attributes[:output_tokens]
    end

    # 触发音频转写。
    #
    # @param audio_file [String] 本地音频文件路径
    # @param kwargs [Hash] 可包含 `:model`、`:language`、`:provider`、
    #   `:assume_model_exists`、`:context`，其余 kwargs 透传给 provider
    # @return [RubyLLM::Transcription]
    def self.transcribe(audio_file, **kwargs)
      model = kwargs.delete(:model)
      language = kwargs.delete(:language)
      provider = kwargs.delete(:provider)
      assume_model_exists = kwargs.delete(:assume_model_exists) { false }
      context = kwargs.delete(:context)
      options = kwargs

      config = context&.config || RubyLLM.config
      model ||= config.default_transcription_model
      model, provider_instance = Models.resolve(model, provider: provider, assume_exists: assume_model_exists,
                                                       config: config)
      model_id = model.id

      provider_instance.transcribe(audio_file, model: model_id, language:, **options)
    end
  end
end
