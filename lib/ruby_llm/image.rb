# frozen_string_literal: true

module RubyLLM
  # Represents a generated image from an AI model.
  #
  # 由模型生成的图像。
  #
  # 不同 provider 返回 URL 或 base64 数据；本类同时持有两种形态，
  # 由 {#base64?} 判断当前是哪一种。{#to_blob} / {#save} 提供统一的
  # 二进制访问。
  class Image
    # @return [String, nil] 图像 URL（DALL·E 等返回链接）
    # @return [String, nil] base64 图像数据（gpt-image 等内嵌返回）
    # @return [String, nil] MIME 类型
    # @return [String, nil] 模型重写后的 prompt（如 DALL·E 3 会优化）
    # @return [String, nil] 模型 ID
    # @return [Hash] 原始 usage 信息（含 token 明细）
    attr_reader :url, :data, :mime_type, :revised_prompt, :model_id, :usage

    def initialize(url: nil, data: nil, mime_type: nil, revised_prompt: nil, model_id: nil, usage: {}) # rubocop:disable Metrics/ParameterLists
      @url = url
      @data = data
      @mime_type = mime_type
      @revised_prompt = revised_prompt
      @model_id = model_id
      @usage = usage
    end

    # 当前实例是否以 base64 形式持有图像数据。
    def base64?
      !@data.nil?
    end

    # 取图像二进制内容；若是 URL 形态会发起一次 HTTP GET。
    #
    # @return [String] 二进制
    def to_blob
      if base64?
        Base64.decode64 @data
      else
        response = Connection.basic.get @url
        response.body
      end
    end

    # 把图像保存到文件。
    #
    # @param path [String]
    # @return [String] 保存后的路径
    def save(path)
      File.binwrite(File.expand_path(path), to_blob)
      path
    end

    # 调用图像生成 / 编辑 API。
    #
    # @param prompt [String]
    # @param model [String, nil] 默认 `config.default_image_model`
    # @param provider [Symbol, nil]
    # @param assume_model_exists [Boolean]
    # @param size [String] 默认 `'1024x1024'`
    # @param context [RubyLLM::Context, nil]
    # @param with [String, nil] 用于编辑的参考图路径
    # @param mask [String, nil] 蒙版路径
    # @param params [Hash] 透传 provider 参数
    # @return [RubyLLM::Image]
    def self.paint(prompt, # rubocop:disable Metrics/ParameterLists
                   model: nil,
                   provider: nil,
                   assume_model_exists: false,
                   size: '1024x1024',
                   context: nil,
                   with: nil,
                   mask: nil,
                   params: {})
      config = context&.config || RubyLLM.config
      model ||= config.default_image_model
      model, provider_instance = Models.resolve(model, provider: provider, assume_exists: assume_model_exists,
                                                       config: config)
      model_id = model.id

      provider_instance.paint(prompt, model: model_id, size:, with:, mask:, params:)
    end

    # 把 usage 字段构造为 {Tokens} 对象。
    def tokens
      @tokens ||= Tokens.build(
        input: usage_value('input_tokens'),
        output: usage_value('output_tokens')
      )
    end

    # 计算图像生成费用（按 :images 计费类目，因为价格与文本不同）。
    def cost
      Cost.new(tokens:, model: model_info, category: :images, input_details: input_tokens_details)
    end

    # 在注册表中查找模型元数据；找不到时返回 nil。
    def model_info
      return unless model_id

      @model_info ||= RubyLLM.models.find(model_id)
    rescue ModelNotFoundError
      nil
    end

    private

    def input_tokens_details
      usage_value('input_tokens_details')
    end

    # 兼容字符串/符号 key 的 usage 取值。
    def usage_value(key)
      usage[key] || usage[key.to_sym]
    end
  end
end
