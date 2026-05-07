# frozen_string_literal: true

module RubyLLM
  module Model
    # Information about an AI model's capabilities, pricing, and metadata.
    #
    # 单个模型的完整元数据。
    #
    # 一条 `Info` 描述一个模型：上下文长度、最大输出、模态、能力、
    # 价格、知识截止日、所属 provider 等。`Models` 注册表把数百条
    # `Info` 加载进内存，{Models#find}、{Models#resolve} 在其上检索。
    #
    # 数据来源：
    # - gem 内置 `models.json`（由 `rake models:refresh` 抓取）
    # - 各 provider 的 `list_models` API（`refresh!` 时合并）
    # - models.dev 公共数据集（补充元数据）
    class Info
      attr_reader :id, :name, :provider, :family, :created_at, :context_window, :max_output_tokens, :knowledge_cutoff,
                  :modalities, :capabilities, :pricing, :metadata

      # Create a default model with assumed capabilities
      #
      # 构造一个"假设存在"的模型 —— 在 `assume_model_exists: true` 场景
      # 中使用，赋予一组合理的默认能力。生成的模型会带 `warning` 元数据
      # 提示能力可能不准确。
      def self.default(model_id, provider)
        new(
          id: model_id,
          name: model_id.tr('-', ' ').capitalize,
          provider: provider,
          capabilities: %w[function_calling streaming vision structured_output],
          modalities: { input: %w[text image], output: %w[text] },
          metadata: { warning: 'Assuming model exists, capabilities may not be accurate' }
        )
      end

      # @param data [Hash] 来自 models.json / API / models.dev 的字段
      def initialize(data)
        @id = data[:id]
        @name = data[:name]
        @provider = data[:provider]
        @family = data[:family]
        @created_at = Utils.to_time(data[:created_at])&.utc
        @context_window = data[:context_window]
        @max_output_tokens = data[:max_output_tokens]
        @knowledge_cutoff = Utils.to_date(data[:knowledge_cutoff])
        @modalities = Modalities.new(data[:modalities] || {})
        @capabilities = data[:capabilities] || []
        @pricing = Pricing.new(data[:pricing] || {})
        @metadata = data[:metadata] || {}
      end

      # 是否声明支持某能力（如 `'function_calling'`、`'streaming'`、
      # `'vision'`、`'structured_output'`、`'reasoning'`、`'citations'`）。
      def supports?(capability)
        capabilities.include?(capability.to_s)
      end

      # 为常见能力批量定义 `xxx?` 谓词方法（如 `function_calling?`）。
      %w[function_calling structured_output batch reasoning citations streaming].each do |cap|
        define_method "#{cap}?" do
          supports?(cap)
        end
      end

      # 用于 UI 展示的友好名称。
      def display_name
        name
      end

      # 形如 `"OpenAI - GPT-5"` 的展示标签。
      def label
        provider_name = provider_class&.name || provider
        "#{provider_name} - #{display_name}"
      end

      # max_output_tokens 的别名。
      def max_tokens
        max_output_tokens
      end

      # 模态层面的视觉支持（输入模态包含 image）。
      def supports_vision?
        modalities.input.include?('image')
      end

      # 模态层面的视频支持。
      def supports_video?
        modalities.input.include?('video')
      end

      # function_calling? 的语义化别名。
      def supports_functions?
        function_calling?
      end

      def input_price_per_million
        pricing.text_tokens.input
      end

      def output_price_per_million
        pricing.text_tokens.output
      end

      def cache_read_input_price_per_million
        pricing.text_tokens.cache_read_input
      end

      def cache_write_input_price_per_million
        pricing.text_tokens.cache_write_input
      end

      alias cached_input_price_per_million cache_read_input_price_per_million
      alias cache_creation_input_price_per_million cache_write_input_price_per_million

      # 根据 token 计数估算费用。
      #
      # @param tokens [RubyLLM::Tokens, #tokens] token 计数对象
      # @return [RubyLLM::Cost]
      def cost_for(tokens)
        tokens = tokens.tokens if tokens.respond_to?(:tokens)

        Cost.new(tokens:, model: self)
      end

      # 该模型对应的 provider 类。
      def provider_class
        RubyLLM::Provider.resolve provider
      end

      # 模型类型推断：根据输出模态判定属于哪一类任务。
      #
      # @return [String] `'chat' | 'embedding' | 'moderation' |
      #   'image' | 'audio' | 'video'`
      def type
        output = modalities.output
        return 'embedding' if output.include?('embeddings')
        return 'moderation' if output.include?('moderation')
        return 'image' if output.include?('image')
        return 'audio' if output.include?('audio')
        return 'video' if output.include?('video')

        'chat'
      end

      def to_h
        {
          id: id,
          name: name,
          provider: provider,
          family: family,
          created_at: created_at,
          context_window: context_window,
          max_output_tokens: max_output_tokens,
          knowledge_cutoff: knowledge_cutoff,
          modalities: modalities.to_h,
          capabilities: capabilities,
          pricing: pricing.to_h,
          metadata: metadata
        }
      end
    end
  end
end
