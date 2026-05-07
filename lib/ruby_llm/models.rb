# frozen_string_literal: true

module RubyLLM
  # Registry of available AI models and their capabilities.
  #
  # 模型注册表 —— 全局单例，承载 800+ 模型的元数据与查找/解析逻辑。
  #
  # 数据流：
  #
  # 1. **加载**（{Models#initialize}）：从 `models.json` 读入；
  #    当应用启用 `acts_as_chat` 时被 monkey-patch 改为先读数据库
  #    （见 `active_record/acts_as.rb`）。
  # 2. **解析**（{Models.resolve}）：把用户给的 `model_id`（可能是别名）
  #    映射到具体的 {Model::Info} 与对应 Provider 实例。这是 Chat、
  #    Embedding 等所有任务的统一入口。
  # 3. **检索**（{#find}）：按 `[id, provider]` 精确查；不指定 provider
  #    时按 {PROVIDER_PREFERENCE} 给出"最优 provider"的版本。
  # 4. **刷新**（{Models.refresh!}）：远程拉取所有已配置 provider 的
  #    模型清单 + 从 models.dev 拉公共元数据，与现有数据合并后落盘。
  #
  # `Enumerable` 由 {#each} 提供（迭代当前所有模型）。
  class Models
    include Enumerable

    # models.dev 的 provider key → RubyLLM provider slug 映射。
    MODELS_DEV_PROVIDER_MAP = {
      'openai' => 'openai',
      'anthropic' => 'anthropic',
      'google' => 'gemini',
      'google-vertex' => 'vertexai',
      'amazon-bedrock' => 'bedrock',
      'deepseek' => 'deepseek',
      'mistral' => 'mistral',
      'openrouter' => 'openrouter',
      'perplexity' => 'perplexity'
    }.freeze

    # 当一个 model id 在多个 provider 上都存在时，按此顺序优先选择
    # （例如 `claude-sonnet-4` 同时在 anthropic / bedrock / vertexai 上
    # 都可用，未指定 provider 时优先 anthropic）。
    PROVIDER_PREFERENCE = %w[
      openai
      anthropic
      gemini
      vertexai
      bedrock
      openrouter
      deepseek
      mistral
      perplexity
      xai
      azure
      ollama
      gpustack
    ].freeze

    class << self
      # 全局单例。
      def instance
        @instance ||= new
      end

      # JSON Schema 文件路径（用于校验 models.json 结构）。
      def schema_file
        File.expand_path('models_schema.json', __dir__)
      end

      # 从默认 / 自定义路径加载模型表。
      # 当应用启用 acts_as 时，此方法会被 monkey-patch 优先读 DB。
      def load_models(file = RubyLLM.config.model_registry_file)
        read_from_json(file)
      end

      # 从 JSON 文件读取并实例化为 Model::Info 列表，做 `filter_models` 清洗。
      # 解析失败时返回空数组（不抛错，让应用启动时有降级）。
      def read_from_json(file = RubyLLM.config.model_registry_file)
        data = File.exist?(file) ? File.read(file) : '[]'
        models = JSON.parse(data, symbolize_names: true).map { |model| Model::Info.new(model) }
        filter_models(models)
      rescue JSON::ParserError
        []
      end

      # 全量刷新模型注册表。
      #
      # @param remote_only [Boolean] 仅刷新远程 provider（跳过 Ollama
      #   等本地 provider）；默认 false
      # @return [Models] 新单例
      def refresh!(remote_only: false)
        existing_models = load_existing_models

        provider_fetch = fetch_provider_models(remote_only: remote_only)
        log_provider_fetch(provider_fetch)

        models_dev_fetch = fetch_models_dev_models(existing_models)
        log_models_dev_fetch(models_dev_fetch)

        merged_models = merge_with_existing(existing_models, provider_fetch, models_dev_fetch)
        @instance = new(merged_models)
      end

      def fetch_provider_models(remote_only: true) # rubocop:disable Metrics/PerceivedComplexity
        config = RubyLLM.config
        provider_classes = remote_only ? Provider.remote_providers.values : Provider.providers.values
        configured_classes = if remote_only
                               Provider.configured_remote_providers(config)
                             else
                               Provider.configured_providers(config)
                             end
        configured = configured_classes.select { |klass| provider_classes.include?(klass) }
        result = {
          models: [],
          fetched_providers: [],
          configured_names: configured.map(&:name),
          failed: []
        }

        provider_classes.each do |provider_class|
          next if remote_only && provider_class.local?
          next unless provider_class.configured?(config)

          begin
            result[:models].concat(provider_class.new(config).list_models)
            result[:fetched_providers] << provider_class.slug
          rescue StandardError => e
            result[:failed] << { name: provider_class.name, slug: provider_class.slug, error: e }
          end
        end

        result[:fetched_providers].uniq!
        result
      end

      # Backwards-compatible wrapper used by specs.
      def fetch_from_providers(remote_only: true)
        fetch_provider_models(remote_only: remote_only)[:models]
      end

      # 解析 model_id 到 [{Model::Info}, {Provider} 实例]。
      #
      # 行为分两路：
      # 1. **assume_exists=true**（或 provider 是 local? / assume_models_exist?）：
      #    跳过注册表查找，直接用 `Model::Info.default` 构造一个"假定
      #    存在"的模型。本地模型（Ollama）会先尝试在注册表中查到真实
      #    元数据。
      # 2. **assume_exists=false**：在注册表中查找；若指定了 provider
      #    则做严格匹配，未指定则按 {PROVIDER_PREFERENCE} 选最佳。
      #
      # @param model_id [String] 模型 ID 或别名
      # @param provider [Symbol, String, nil]
      # @param assume_exists [Boolean]
      # @param config [Configuration, nil]
      # @return [Array(Model::Info, Provider)]
      # @raise [ArgumentError] assume_exists=true 但未指定 provider
      # @raise [Error] provider slug 未注册
      # @raise [ModelNotFoundError] 注册表中找不到
      def resolve(model_id, provider: nil, assume_exists: false, config: nil) # rubocop:disable Metrics/PerceivedComplexity
        config ||= RubyLLM.config
        provider_class = provider ? Provider.providers[provider.to_sym] : nil

        if provider_class
          temp_instance = provider_class.new(config)
          assume_exists = true if temp_instance.local? || temp_instance.assume_models_exist?
        end

        if assume_exists
          raise ArgumentError, 'Provider must be specified if assume_exists is true' unless provider

          provider_class ||= raise(Error, "Unknown provider: #{provider.to_sym}")
          provider_instance = provider_class.new(config)

          model = if provider_instance.local?
                    begin
                      Models.find(model_id, provider)
                    rescue ModelNotFoundError
                      nil
                    end
                  end

          model ||= Model::Info.default(model_id, provider_instance.slug)
        else
          model = Models.find model_id, provider
          provider_class = Provider.providers[model.provider.to_sym] || raise(Error,
                                                                              "Unknown provider: #{model.provider}")
          provider_instance = provider_class.new(config)
        end
        [model, provider_instance]
      end

      # 把所有未匹配的类方法转发给 instance —— 使得 `RubyLLM.models.find`
      # 与 `RubyLLM::Models.find` 行为一致。
      def method_missing(method, ...)
        if instance.respond_to?(method)
          instance.send(method, ...)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        instance.respond_to?(method, include_private) || super
      end

      def fetch_models_dev_models(existing_models) # rubocop:disable Metrics/PerceivedComplexity
        RubyLLM.logger.info 'Fetching models from models.dev API...'

        connection = Connection.basic do |f|
          f.request :json
          f.response :json, parser_options: { symbolize_names: true }
        end
        response = connection.get 'https://models.dev/api.json'
        providers = response.body || {}

        models = providers.flat_map do |provider_key, provider_data|
          provider_slug = MODELS_DEV_PROVIDER_MAP[provider_key.to_s]
          next [] unless provider_slug

          (provider_data[:models] || {}).values.map do |model_data|
            Model::Info.new(models_dev_model_to_info(model_data, provider_slug, provider_key.to_s))
          end
        end
        { models: models.reject { |model| model.provider.nil? || model.id.nil? }, fetched: true }
      rescue StandardError => e
        RubyLLM.logger.warn("Failed to fetch models.dev (#{e.class}: #{e.message}). Keeping existing.")
        {
          models: existing_models.select { |model| model.metadata[:source] == 'models.dev' },
          fetched: false
        }
      end

      def load_existing_models
        existing_models = instance&.all
        existing_models = read_from_json if existing_models.nil? || existing_models.empty?
        existing_models
      end

      def log_provider_fetch(provider_fetch)
        RubyLLM.logger.info "Fetching models from providers: #{provider_fetch[:configured_names].join(', ')}"
        provider_fetch[:failed].each do |failure|
          RubyLLM.logger.warn(
            "Failed to fetch #{failure[:name]} models (#{failure[:error].class}: #{failure[:error].message}). " \
            'Keeping existing.'
          )
        end
      end

      def log_models_dev_fetch(models_dev_fetch)
        return if models_dev_fetch[:fetched]

        RubyLLM.logger.warn('Using cached models.dev data due to fetch failure.')
      end

      def merge_with_existing(existing_models, provider_fetch, models_dev_fetch)
        existing_by_provider = existing_models.group_by(&:provider)
        preserved_models = existing_by_provider
                           .except(*provider_fetch[:fetched_providers])
                           .values
                           .flatten

        provider_models = provider_fetch[:models] + preserved_models
        models_dev_models = if models_dev_fetch[:fetched]
                              models_dev_fetch[:models]
                            else
                              existing_models.select { |model| model.metadata[:source] == 'models.dev' }
                            end

        merge_models(provider_models, models_dev_models)
      end

      def merge_models(provider_models, models_dev_models)
        models_dev_by_key = index_by_key(models_dev_models)
        provider_by_key = index_by_key(provider_models)

        all_keys = models_dev_by_key.keys | provider_by_key.keys

        models = all_keys.map do |key|
          models_dev_model = find_models_dev_model(key, models_dev_by_key)
          provider_model = provider_by_key[key]

          if models_dev_model && provider_model
            add_provider_metadata(models_dev_model, provider_model)
          elsif models_dev_model
            models_dev_model
          else
            provider_model
          end
        end

        filter_models(models).sort_by { |m| [m.provider, m.id] }
      end

      def filter_models(models)
        models.reject do |model|
          model.provider.to_s == 'vertexai' && model.id.to_s.include?('/')
        end
      end

      def find_models_dev_model(key, models_dev_by_key)
        # Direct match
        return models_dev_by_key[key] if models_dev_by_key[key]

        provider, model_id = key.split(':', 2)
        if provider == 'bedrock'
          normalized_id = model_id.sub(/^[a-z]{2}\./, '')
          context_override = nil
          normalized_id = normalized_id.gsub(/:(\d+)k\b/) do
            context_override = Regexp.last_match(1).to_i * 1000
            ''
          end
          bedrock_model = models_dev_by_key["bedrock:#{normalized_id}"]
          if bedrock_model
            data = bedrock_model.to_h.merge(id: model_id)
            data[:context_window] = context_override if context_override
            return Model::Info.new(data)
          end
        end

        # VertexAI uses same models as Gemini
        return unless provider == 'vertexai'

        gemini_model = models_dev_by_key["gemini:#{model_id}"]
        return unless gemini_model

        # Return Gemini's models.dev data but with VertexAI as provider
        Model::Info.new(gemini_model.to_h.merge(provider: 'vertexai'))
      end

      def index_by_key(models)
        models.to_h do |model|
          ["#{model.provider}:#{model.id}", model]
        end
      end

      def add_provider_metadata(models_dev_model, provider_model) # rubocop:disable Metrics/PerceivedComplexity
        data = models_dev_model.to_h
        data[:name] = provider_model.name if blank_value?(data[:name])
        data[:family] = provider_model.family if blank_value?(data[:family])
        data[:created_at] = provider_model.created_at if blank_value?(data[:created_at])
        data[:context_window] = provider_model.context_window if blank_value?(data[:context_window])
        data[:max_output_tokens] = provider_model.max_output_tokens if blank_value?(data[:max_output_tokens])
        data[:modalities] = provider_model.modalities.to_h if blank_value?(data[:modalities])
        data[:pricing] = provider_model.pricing.to_h if blank_value?(data[:pricing])
        data[:metadata] = provider_model.metadata.merge(data[:metadata] || {})
        data[:capabilities] = (models_dev_model.capabilities + provider_model.capabilities).uniq
        normalize_embedding_modalities(data)
        Model::Info.new(data)
      end

      def normalize_embedding_modalities(data)
        return unless data[:id].to_s.include?('embedding')

        modalities = data[:modalities].to_h
        modalities[:input] = ['text'] if modalities[:input].nil? || modalities[:input].empty?
        modalities[:output] = ['embeddings']
        data[:modalities] = modalities
      end

      def blank_value?(value)
        return true if value.nil?
        return value.empty? if value.is_a?(String) || value.is_a?(Array)

        if value.is_a?(Hash)
          return true if value.empty?

          return value.values.all? { |nested| blank_value?(nested) }
        end

        false
      end

      def models_dev_model_to_info(model_data, provider_slug, provider_key)
        modalities = normalize_models_dev_modalities(model_data[:modalities])
        capabilities = models_dev_capabilities(model_data, modalities)

        created_date = [model_data[:release_date], model_data[:last_updated]]
                       .find { |value| !value.to_s.strip.empty? }

        data = {
          id: model_data[:id],
          name: model_data[:name] || model_data[:id],
          provider: provider_slug,
          family: model_data[:family],
          created_at: created_date ? "#{created_date} 00:00:00 UTC" : nil,
          context_window: model_data.dig(:limit, :context),
          max_output_tokens: model_data.dig(:limit, :output),
          knowledge_cutoff: normalize_models_dev_knowledge(model_data[:knowledge]),
          modalities: modalities,
          capabilities: capabilities,
          pricing: models_dev_pricing(model_data[:cost]),
          metadata: models_dev_metadata(model_data, provider_key)
        }

        normalize_embedding_modalities(data)
        data
      end

      def models_dev_capabilities(model_data, modalities)
        capabilities = []
        capabilities << 'function_calling' if model_data[:tool_call]
        capabilities << 'structured_output' if model_data[:structured_output]
        capabilities << 'reasoning' if model_data[:reasoning]
        capabilities << 'vision' if modalities[:input].intersect?(%w[image video pdf])
        capabilities.uniq
      end

      def models_dev_pricing(cost)
        return {} unless cost

        text_standard = {
          input_per_million: cost[:input],
          output_per_million: cost[:output],
          cache_read_input_per_million: cost[:cache_read],
          cache_write_input_per_million: cost[:cache_write],
          reasoning_output_per_million: cost[:reasoning]
        }.compact

        audio_standard = {
          input_per_million: cost[:input_audio],
          output_per_million: cost[:output_audio]
        }.compact

        pricing = {}
        pricing[:text_tokens] = { standard: text_standard } if text_standard.any?
        pricing[:audio_tokens] = { standard: audio_standard } if audio_standard.any?
        pricing
      end

      def models_dev_metadata(model_data, provider_key)
        metadata = {
          source: 'models.dev',
          provider_id: provider_key,
          open_weights: model_data[:open_weights],
          attachment: model_data[:attachment],
          temperature: model_data[:temperature],
          last_updated: model_data[:last_updated],
          status: model_data[:status],
          interleaved: model_data[:interleaved],
          cost: model_data[:cost],
          limit: model_data[:limit],
          knowledge: model_data[:knowledge]
        }
        metadata.compact
      end

      def normalize_models_dev_modalities(modalities)
        normalized = { input: [], output: [] }
        return normalized unless modalities

        normalized[:input] = Array(modalities[:input]).compact
        normalized[:output] = Array(modalities[:output]).compact
        normalized
      end

      def normalize_models_dev_knowledge(value)
        return if value.nil?
        return value if value.is_a?(Date)

        Date.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end

    # @param models [Array<Model::Info>, nil] 显式注入模型列表（用于
    #   测试）；nil 时调用类级 `load_models` 加载
    def initialize(models = nil)
      @models = self.class.filter_models(models || self.class.load_models)
    end

    # 重新从 JSON 文件加载（覆盖当前实例数据）。
    def load_from_json!(file = RubyLLM.config.model_registry_file)
      @models = self.class.read_from_json(file)
    end

    # 把当前模型列表写回 JSON 文件（refresh! 后落盘）。
    def save_to_json(file = RubyLLM.config.model_registry_file)
      File.write(file, JSON.pretty_generate(all.map(&:to_h)))
    end

    # @return [Array<Model::Info>]
    def all = @models

    # Enumerable 接口实现。
    def each(&)
      all.each(&)
    end

    # 在注册表中查找模型。
    #
    # @param model_id [String]
    # @param provider [Symbol, String, nil]
    # @return [Model::Info]
    # @raise [ModelNotFoundError] 找不到时
    def find(model_id, provider = nil)
      if provider
        find_with_provider(model_id, provider)
      else
        find_without_provider(model_id)
      end
    end

    # 仅 chat 模型的子集（返回新 Models 实例）。
    def chat_models
      self.class.new(all.select { |m| m.type == 'chat' })
    end

    # 仅 embedding 模型。
    def embedding_models
      self.class.new(all.select { |m| m.type == 'embedding' || m.modalities.output.include?('embeddings') })
    end

    # 仅音频模型。
    def audio_models
      self.class.new(all.select { |m| m.type == 'audio' || m.modalities.output.include?('audio') })
    end

    # 仅图像模型。
    def image_models
      self.class.new(all.select { |m| m.type == 'image' || m.modalities.output.include?('image') })
    end

    # 按家族（如 `'gpt-5'`、`'claude-sonnet'`）过滤。
    def by_family(family)
      self.class.new(all.select { |m| m.family == family.to_s })
    end

    # 按 provider 过滤。
    def by_provider(provider)
      self.class.new(all.select { |m| m.provider == provider.to_s })
    end

    def refresh!(remote_only: false)
      self.class.refresh!(remote_only: remote_only)
    end

    def resolve(model_id, provider: nil, assume_exists: false, config: nil)
      self.class.resolve(model_id, provider: provider, assume_exists: assume_exists, config: config)
    end

    private

    # 严格匹配：先把别名解析为真实 ID，再按 (id, provider) 查找。
    # Bedrock 还需要应用区域前缀（cross-region inference profile）。
    def find_with_provider(model_id, provider)
      resolved_id = Aliases.resolve(model_id, provider)
      resolved_id = resolve_bedrock_region_id(resolved_id) if provider.to_s == 'bedrock'
      all.find { |m| m.id == resolved_id && m.provider == provider.to_s } ||
        all.find { |m| m.id == model_id && m.provider == provider.to_s } ||
        raise(ModelNotFoundError, "Unknown model: #{model_id} for provider: #{provider}")
    end

    def resolve_bedrock_region_id(model_id)
      region = RubyLLM.config.bedrock_region.to_s
      return model_id if region.empty?

      candidate_id = Providers::Bedrock::Models.with_region_prefix(model_id, region)
      return model_id if candidate_id == model_id

      candidate = all.find { |m| m.provider == 'bedrock' && m.id == candidate_id }
      return model_id unless candidate

      inference_types = Array(candidate.metadata[:inference_types] || candidate.metadata['inference_types'])
      Providers::Bedrock::Models.normalize_inference_profile_id(model_id, inference_types, region)
    end

    # 不指定 provider 时的查找：先精确按 ID 找；若多个 provider 都有，
    # 按 {PROVIDER_PREFERENCE} 选一；都找不到则别名解析后再来一次。
    def find_without_provider(model_id)
      exact_matches = all.select { |m| m.id == model_id }
      return preferred_match(exact_matches) if exact_matches.any?

      resolved_id = Aliases.resolve(model_id)
      alias_matches = all.select { |m| m.id == resolved_id }
      return preferred_match(alias_matches) if alias_matches.any?

      raise(ModelNotFoundError, "Unknown model: #{model_id}")
    end

    # 多个候选时按 PROVIDER_PREFERENCE 顺序取第一个；没在偏好列表里
    # 的 provider 排到最后。
    def preferred_match(candidates)
      return candidates.first if candidates.size == 1

      candidates.min_by do |model|
        index = PROVIDER_PREFERENCE.index(model.provider)
        index || PROVIDER_PREFERENCE.length
      end
    end
  end
end
