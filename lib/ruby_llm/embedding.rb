# frozen_string_literal: true

module RubyLLM
  # Core embedding interface.
  #
  # 文本嵌入向量任务封装。
  #
  # 即时调用，不持有会话状态。`{RubyLLM.embed}` 直接委托到 {.embed}，
  # 该方法解析模型、调用 provider 的 `embed`，返回带向量与 token 计数的
  # `Embedding` 对象。
  class Embedding
    # @return [Array<Array<Float>>, Array<Float>] 向量（批量时为二维数组）
    # @return [String, RubyLLM::Model::Info] 解析后的模型
    # @return [Integer] 输入 token 数
    attr_reader :vectors, :model, :input_tokens

    def initialize(vectors:, model:, input_tokens: 0)
      @vectors = vectors
      @model = model
      @input_tokens = input_tokens
    end

    # 生成嵌入向量。
    #
    # @param text [String, Array<String>] 文本（支持批量）
    # @param model [String, nil] 模型 ID/别名，默认 `config.default_embedding_model`
    # @param provider [Symbol, nil] 显式指定 provider
    # @param assume_model_exists [Boolean] 是否跳过注册表校验
    # @param context [RubyLLM::Context, nil] 局部上下文
    # @param dimensions [Integer, nil] 输出维度（部分模型支持降维）
    # @return [RubyLLM::Embedding]
    def self.embed(text, # rubocop:disable Metrics/ParameterLists
                   model: nil,
                   provider: nil,
                   assume_model_exists: false,
                   context: nil,
                   dimensions: nil)
      config = context&.config || RubyLLM.config
      model ||= config.default_embedding_model
      model, provider_instance = Models.resolve(model, provider: provider, assume_exists: assume_model_exists,
                                                       config: config)
      model_id = model.id

      provider_instance.embed(text, model: model_id, dimensions:)
    end
  end
end
