# frozen_string_literal: true

module RubyLLM
  # Base class for LLM providers.
  #
  # 所有 LLM Provider 实现的基类。
  #
  # 设计模式：模板方法 + 多 mixin 组合。
  # 子类需要实现：
  #   - `api_base` —— API 根地址
  #   - `headers` —— 认证及自定义请求头
  #   - `completion_url` / `models_url` / `embedding_url(model:)` /
  #     `moderation_url` / `images_url` / `transcription_url`
  #   - `render_payload(messages, ...)` —— 请求体序列化
  #   - `parse_completion_response(response)` —— 响应反序列化
  #   - 其他 endpoint 的 render_*/parse_* 对（按支持能力）
  #
  # 各家 provider 通常通过 `include` 子目录下的 mixin（Chat、Embeddings、
  # Tools、Media、Streaming、Models...）来分别注入这些方法。
  #
  # 类级注册表：`Provider.providers` 持有 `slug => 类` 的全局映射，
  # `RubyLLM::Provider.register` 在 `lib/ruby_llm.rb` 末尾被调用。
  class Provider
    include Streaming

    # @!attribute [r] config
    #   @return [RubyLLM::Configuration]
    # @!attribute [r] connection
    #   @return [RubyLLM::Connection]
    attr_reader :config, :connection

    # 实例化 provider。会在构造时校验配置并立即建立 Connection。
    #
    # @param config [RubyLLM::Configuration]
    # @raise [ConfigurationError] 缺少必需配置项时
    def initialize(config)
      @config = config
      ensure_configured!
      @connection = Connection.new(self, @config)
    end

    # API 根地址。子类必须实现。
    # @return [String]
    def api_base
      raise NotImplementedError
    end

    # 自定义 HTTP 请求头（认证、组织 ID 等）。子类按需覆盖。
    # @return [Hash{String => String}]
    def headers
      {}
    end

    # provider 唯一短标识（如 `:openai`、`:anthropic`）。
    # @return [Symbol]
    def slug
      self.class.slug
    end

    # provider 名称（用于日志、错误消息）。
    # @return [String]
    def name
      self.class.name
    end

    # 该 provider 的能力描述类（用于判断模型能否支持视觉、工具等）。
    # @return [Module, nil]
    def capabilities
      self.class.capabilities
    end

    # 该 provider 必填的配置项列表（如 `[:openai_api_key]`）。
    # @return [Array<Symbol>]
    def configuration_requirements
      self.class.configuration_requirements
    end

    # rubocop:disable Metrics/ParameterLists
    # 执行一次补全请求 —— Chat#complete 的下层入口。
    #
    # @param messages [Array<RubyLLM::Message>] 消息历史
    # @param tools [Hash{Symbol => RubyLLM::Tool}] 已注册工具
    # @param temperature [Float, nil] 采样温度（可能被 normalize 调整）
    # @param model [RubyLLM::Model::Info] 模型对象
    # @param params [Hash] 透传给 provider 的额外字段
    # @param headers [Hash] 额外 HTTP 头
    # @param schema [Hash, nil] 结构化输出 schema
    # @param thinking [RubyLLM::Thinking::Config, nil] 思考预算
    # @param tool_prefs [Hash, nil] 工具选择偏好
    # @yield [chunk] 流式响应回调（可选）
    # @return [RubyLLM::Message]
    def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil,
                 tool_prefs: nil, &)
      normalized_temperature = maybe_normalize_temperature(temperature, model)

      payload = Utils.deep_merge(
        render_payload(
          messages,
          tools: tools,
          tool_prefs: tool_prefs,
          temperature: normalized_temperature,
          model: model,
          stream: block_given?,
          schema: schema,
          thinking: thinking
        ),
        params
      )

      if block_given?
        stream_response @connection, payload, headers, &
      else
        sync_response @connection, payload, headers
      end
    end
    # rubocop:enable Metrics/ParameterLists

    # 拉取该 provider 的可用模型列表。
    # @return [Array<RubyLLM::Model::Info>]
    def list_models
      response = @connection.get models_url
      parse_list_models_response response, slug, capabilities
    end

    # 生成文本嵌入。
    #
    # @param text [String, Array<String>] 待嵌入的文本（支持批量）
    # @param model [String, RubyLLM::Model::Info] 嵌入模型
    # @param dimensions [Integer, nil] 输出维度（部分模型支持降维）
    # @return [RubyLLM::Embedding]
    def embed(text, model:, dimensions:)
      payload = render_embedding_payload(text, model:, dimensions:)
      response = @connection.post(embedding_url(model:), payload)
      parse_embedding_response(response, model:, text:)
    end

    # 内容审核。
    #
    # @param input [String]
    # @param model [String]
    # @return [RubyLLM::Moderation]
    def moderate(input, model:)
      payload = render_moderation_payload(input, model:)
      response = @connection.post moderation_url, payload
      parse_moderation_response(response, model:)
    end

    # 图像生成 / 编辑。
    #
    # @param prompt [String]
    # @param model [String]
    # @param size [String] 例如 `'1024x1024'`
    # @param with [String, nil] 用于编辑的参考图路径
    # @param mask [String, nil] 蒙版路径
    # @param params [Hash] 透传参数
    # @return [RubyLLM::Image]
    def paint(prompt, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists
      validate_paint_inputs!(with:, mask:)
      payload = render_image_payload(prompt, model:, size:, with:, mask:, params:)
      response = @connection.post images_url(with:, mask:), payload
      parse_image_response(response, model:)
    end

    # 音频转写。
    #
    # @param audio_file [String] 本地文件路径
    # @param model [String]
    # @param language [String, nil] ISO 语言代码（如 `'zh'`、`'en'`）
    # @return [RubyLLM::Transcription]
    def transcribe(audio_file, model:, language:, **options)
      file_part = build_audio_file_part(audio_file)
      payload = render_transcription_payload(file_part, model:, language:, **options)
      response = @connection.post transcription_url, payload
      parse_transcription_response(response, model:)
    end

    # 实例级"是否已配置完整"检查。
    # @return [Boolean]
    def configured?
      configuration_requirements.all? { |req| @config.send(req) }
    end

    # 是否为本地 provider（如 Ollama、GPUStack）。
    def local?
      self.class.local?
    end

    # 是否为远程 provider（与 local? 互斥）。
    def remote?
      self.class.remote?
    end

    # 该 provider 是否允许以 `assume_model_exists` 方式跳过注册表校验。
    def assume_models_exist?
      self.class.assume_models_exist?
    end

    # 从 HTTP 错误响应中抽取人类可读的错误消息。
    # 默认实现尝试解析 JSON，并在常见的几种结构（hash / array、
    # `error` 是字符串 / hash）中提取 `message` 字段；子类可覆盖以
    # 适配 provider 的具体格式。
    #
    # @param response [Faraday::Response]
    # @return [String, nil]
    def parse_error(response)
      return if response.body.empty?

      body = try_parse_json(response.body)
      case body
      when Hash
        error = body['error']
        return error if error.is_a?(String)

        body.dig('error', 'message')
      when Array
        body.map do |part|
          error = part['error']
          error.is_a?(String) ? error : part.dig('error', 'message')
        end.join('. ')
      else
        body
      end
    end

    # 把消息历史转成最朴素的 `[{role:, content:}]` 形式。子类通常覆盖
    # 以处理多模态、工具调用、缓存控制等细节。
    def format_messages(messages)
      messages.map do |msg|
        {
          role: msg.role.to_s,
          content: msg.content
        }
      end
    end

    # 把工具调用渲染到请求体（默认不渲染；子类按需实现）。
    def format_tool_calls(_tool_calls)
      nil
    end

    # 解析响应体中的工具调用（默认无；子类按需实现）。
    def parse_tool_calls(_tool_calls)
      nil
    end

    class << self
      # 默认从类常量名推导名称（如 `RubyLLM::Providers::OpenAI` → `'OpenAI'`）。
      def name
        to_s.split('::').last
      end

      # 默认从名称小写得到 slug（`'OpenAI'` → `'openai'`）。
      def slug
        name.downcase
      end

      # 能力描述模块（用于 model 注册表的 capability 判断）。
      def capabilities
        nil
      end

      # 必填配置项列表（如 `[:openai_api_key]`）。子类需声明。
      def configuration_requirements
        []
      end

      # 该 provider 注入到全局 Configuration 的所有键（必填+可选）。
      def configuration_options
        []
      end

      # 是否本地 provider。
      def local?
        false
      end

      def remote?
        !local?
      end

      # 是否允许 `assume_model_exists`。
      def assume_models_exist?
        false
      end

      # 类级"是否已配置完整"判定（不需要实例）。
      def configured?(config)
        configuration_requirements.all? { |req| config.send(req) }
      end

      # 把 provider 类注册到全局表，并把它的配置选项注入 Configuration。
      #
      # @param name [Symbol] slug
      # @param provider_class [Class<Provider>]
      def register(name, provider_class)
        providers[name.to_sym] = provider_class
        RubyLLM::Configuration.register_provider_options(provider_class.configuration_options)
      end

      # 通过 slug 查找 provider 类。
      def resolve(name)
        providers[name.to_sym]
      end

      # 给定模型 ID，查注册表得到 provider slug，再 resolve 得到类。
      def for(model)
        model_info = Models.find(model)
        resolve model_info.provider
      end

      # 全局 provider 注册表（`{slug => 类}`）。
      def providers
        @providers ||= {}
      end

      def local_providers
        providers.select { |_slug, provider_class| provider_class.local? }
      end

      def remote_providers
        providers.select { |_slug, provider_class| provider_class.remote? }
      end

      # 已配置（凭据齐全）的所有 provider 类。
      def configured_providers(config)
        providers.select do |_slug, provider_class|
          provider_class.configured?(config)
        end.values
      end

      # 已配置且为远程的 provider 类（用于自动刷新模型列表）。
      def configured_remote_providers(config)
        providers.select do |_slug, provider_class|
          provider_class.remote? && provider_class.configured?(config)
        end.values
      end
    end

    private

    # 默认 paint 不支持图片引用；支持的子类覆盖此方法。
    def validate_paint_inputs!(with:, mask:)
      return if with.nil? && mask.nil?

      raise UnsupportedAttachmentError, "#{name} does not support image references in paint"
    end

    # 把音频文件路径包装为 multipart 文件块（自动检测 MIME 类型）。
    def build_audio_file_part(file_path)
      expanded_path = File.expand_path(file_path)
      mime_type = Marcel::MimeType.for(Pathname.new(expanded_path))

      Faraday::Multipart::FilePart.new(
        expanded_path,
        mime_type,
        File.basename(expanded_path)
      )
    end

    # 容错的 JSON 解析：解析失败/非字符串时原样返回。
    def try_parse_json(maybe_json)
      return maybe_json unless maybe_json.is_a?(String)

      JSON.parse(maybe_json)
    rescue JSON::ParserError
      maybe_json
    end

    # 实例级配置校验（initialize 时调用）。
    def ensure_configured!
      missing = configuration_requirements.reject { |req| @config.send(req) }
      return if missing.empty?

      raise ConfigurationError, "Missing configuration for #{name}: #{missing.join(', ')}"
    end

    # 子类钩子：根据模型对温度做 normalize（如 OpenAI o-系列必须为 1.0）。
    def maybe_normalize_temperature(temperature, _model)
      temperature
    end

    # 同步（非流式）补全实现。
    def sync_response(connection, payload, additional_headers = {})
      response = connection.post completion_url, payload do |req|
        req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
      end
      parse_completion_response response
    end
  end
end
