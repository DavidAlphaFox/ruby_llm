# frozen_string_literal: true

module RubyLLM
  # Identify potentially harmful content in text.
  # https://platform.openai.com/docs/guides/moderation
  #
  # 内容审核任务封装。
  #
  # 调用 OpenAI Moderation 等 API，识别文本中的有害内容。返回 results
  # 数组（每个输入对应一个结果），每项含 `flagged` 标志、`categories`
  # 各类别命中、`category_scores` 各类别得分。
  class Moderation
    # @return [String] 请求 ID
    # @return [String] 使用的模型
    # @return [Array<Hash>] 各输入的审核结果
    attr_reader :id, :model, :results

    def initialize(id:, model:, results:)
      @id = id
      @model = model
      @results = results
    end

    # 触发内容审核。
    #
    # @param input [String, Array<String>]
    # @param model [String, nil] 默认 `config.default_moderation_model`
    # @param provider [Symbol, nil]
    # @param assume_model_exists [Boolean]
    # @param context [RubyLLM::Context, nil]
    # @return [RubyLLM::Moderation]
    def self.moderate(input,
                      model: nil,
                      provider: nil,
                      assume_model_exists: false,
                      context: nil)
      config = context&.config || RubyLLM.config
      model ||= config.default_moderation_model || 'omni-moderation-latest'
      model, provider_instance = Models.resolve(model, provider: provider, assume_exists: assume_model_exists,
                                                       config: config)
      model_id = model.id

      provider_instance.moderate(input, model: model_id)
    end

    # results 的别名，让审核对象与 Chat 结果有相似的访问接口。
    def content
      results
    end

    # 是否存在被标记为违规的输入。
    def flagged?
      results.any? { |result| result['flagged'] }
    end

    # 返回**所有结果中**被命中的类别名集合（去重）。
    def flagged_categories
      results.flat_map do |result|
        result['categories']&.select { |_category, flagged| flagged }&.keys || []
      end.uniq
    end

    # 取**第一个**结果的各类别得分（最常用的单输入场景）。
    def category_scores
      results.first&.dig('category_scores') || {}
    end

    # 取**第一个**结果的各类别命中（布尔）。
    def categories
      results.first&.dig('categories') || {}
    end
  end
end
