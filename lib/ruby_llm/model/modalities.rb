# frozen_string_literal: true

module RubyLLM
  module Model
    # Holds and manages input and output modalities for a language model
    #
    # 模型的输入/输出模态描述。
    #
    # 常见值：`text`、`image`、`audio`、`video`、`pdf`、`embeddings`、
    # `moderation`。
    # 例如 GPT-4o：input=[text, image, audio]，output=[text]；
    # text-embedding-3-small：input=[text]，output=[embeddings]。
    class Modalities
      # @return [Array<String>] 输入模态列表
      # @return [Array<String>] 输出模态列表
      attr_reader :input, :output

      def initialize(data)
        @input = Array(data[:input]).map(&:to_s)
        @output = Array(data[:output]).map(&:to_s)
      end

      def to_h
        {
          input: input,
          output: output
        }
      end
    end
  end
end
