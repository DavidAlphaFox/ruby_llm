# frozen_string_literal: true

module RubyLLM
  # Connection class for managing API connections to various providers.
  #
  # 封装单个 Provider 的 Faraday HTTP 连接。
  #
  # 一个 Provider 实例对应一个 `Connection` 实例。本类负责：
  #
  # - 装配 Faraday：设置 base url、超时、日志（含敏感数据过滤）、
  #   重试中间件、JSON/multipart 编解码、错误中间件、HTTP 代理。
  # - 发送 GET / POST 请求时**自动合并** `provider.headers`（如认证头）。
  # - 在初始化时校验 provider 必需的配置项是否齐全（缺则抛出
  #   {ConfigurationError} 并给出可复制的修复代码片段）。
  #
  # 不可变性：一旦构造完成，连接对象会被 Provider 持有；切换模型时
  # 会换 Provider，但同一 Provider 内部保持单一连接。
  class Connection
    # @!attribute [r] provider
    #   @return [RubyLLM::Provider] 拥有该连接的 provider
    # @!attribute [r] connection
    #   @return [Faraday::Connection] 底层 Faraday 实例
    # @!attribute [r] config
    #   @return [RubyLLM::Configuration] 用于构造该连接的配置快照
    attr_reader :provider, :connection, :config

    # 构造一个**轻量的** Faraday 连接（不带认证/重试/错误映射）。
    #
    # 用于工具脚本（如 `rake models:refresh` 抓取模型列表）。
    #
    # @yield [faraday] Faraday 配置块
    # @return [Faraday::Connection]
    def self.basic(&)
      Faraday.new do |f|
        f.response :logger,
                   RubyLLM.logger,
                   bodies: false,
                   errors: true,
                   headers: false,
                   log_level: :debug
        f.response :raise_error
        yield f if block_given?
      end
    end

    # 构造与某 Provider 绑定的连接。
    #
    # @param provider [RubyLLM::Provider] 已实例化的 provider
    # @param config [RubyLLM::Configuration] 当前配置（含超时、重试、
    #   API key 等所需字段）
    # @raise [ConfigurationError] 当 provider 必需的凭据缺失时
    def initialize(provider, config)
      @provider = provider
      @config = config

      ensure_configured!
      @connection ||= Faraday.new(provider.api_base) do |faraday|
        setup_timeout(faraday)
        setup_logging(faraday)
        setup_retry(faraday)
        setup_middleware(faraday)
        setup_http_proxy(faraday)
      end
    end

    # 发送 POST 请求，自动合并 provider 认证头。
    #
    # @param url [String] 相对路径或完整 URL
    # @param payload [Hash, Faraday::Multipart::FilePart] 请求体
    # @yield [req] 可选的请求定制块（如设置 `req.options.on_data` 用于流式）
    # @return [Faraday::Response]
    def post(url, payload, &)
      @connection.post url, payload do |req|
        req.headers.merge! @provider.headers if @provider.respond_to?(:headers)
        yield req if block_given?
      end
    end

    # 发送 GET 请求，自动合并 provider 认证头。
    #
    # @param url [String]
    # @yield [req]
    # @return [Faraday::Response]
    def get(url, &)
      @connection.get url do |req|
        req.headers.merge! @provider.headers if @provider.respond_to?(:headers)
        yield req if block_given?
      end
    end

    # 覆盖 `instance_variables` 以隐藏 config 与底层 connection，
    # 避免 inspect 输出大量 Faraday 内部细节。
    def instance_variables
      super - %i[@config @connection]
    end

    private

    # 设置请求超时（秒）。
    def setup_timeout(faraday)
      faraday.options.timeout = @config.request_timeout
    end

    # 装配 Faraday logger 中间件。
    # 关键细节：通过 `logger.filter` 把 base64 数据块和巨大的
    # 浮点数组（embedding）替换成占位符，避免日志被冗长的二进制/向量
    # 数据淹没。
    def setup_logging(faraday)
      faraday.response :logger,
                       RubyLLM.logger,
                       bodies: RubyLLM.logger.debug?,
                       errors: true,
                       headers: false,
                       log_level: :debug do |logger|
        logger.filter(logging_regexp('[A-Za-z0-9+/=]{100,}'), '[BASE64 DATA]')
        logger.filter(logging_regexp('[-\\d.e,\\s]{100,}'), '[EMBEDDINGS ARRAY]')
      end
    end

    # 构造正则；在 Ruby 3.2+ 上附带 timeout 防御 ReDoS。
    def logging_regexp(pattern)
      return Regexp.new(pattern) if @config.log_regexp_timeout.nil? || !Regexp.respond_to?(:timeout)

      Regexp.new(pattern, timeout: @config.log_regexp_timeout)
    end

    # 装配重试中间件。
    # 注意：Faraday::Retry 默认只重试幂等方法（GET/HEAD/...）；这里
    # **显式添加 :post**，因为 LLM API 的多数失败（限流、5xx）即使
    # 重发 POST 也是安全的（提供商支持幂等键时由 provider 层另外处理）。
    def setup_retry(faraday)
      faraday.request :retry, {
        max: @config.max_retries,
        interval: @config.retry_interval,
        interval_randomness: @config.retry_interval_randomness,
        backoff_factor: @config.retry_backoff_factor,
        methods: Faraday::Retry::Middleware::IDEMPOTENT_METHODS + [:post],
        exceptions: retry_exceptions
      }
    end

    # 装配请求/响应中间件链。
    # 顺序很关键：multipart → json 编码 → json 解码 → 适配器 →
    # llm_errors（最后一个 use 在 on_complete 链最前面执行）。
    def setup_middleware(faraday)
      faraday.request :multipart
      faraday.request :json
      faraday.response :json
      faraday.adapter :net_http
      faraday.use :llm_errors, provider: @provider
    end

    # 配置 HTTP 代理（若用户在 config 中提供）。
    def setup_http_proxy(faraday)
      return unless @config.http_proxy

      faraday.proxy = @config.http_proxy
    end

    # 触发自动重试的异常类型集合 —— 既包含网络层（超时/连接失败），
    # 也包含被 ErrorMiddleware 转换出的 RubyLLM 错误（限流、5xx、过载）。
    def retry_exceptions
      [
        Errno::ETIMEDOUT,
        Timeout::Error,
        Faraday::TimeoutError,
        Faraday::ConnectionFailed,
        Faraday::RetriableResponse,
        RubyLLM::RateLimitError,
        RubyLLM::ServerError,
        RubyLLM::ServiceUnavailableError,
        RubyLLM::OverloadedError
      ]
    end

    # 校验 provider 的必填配置项；缺失时抛出友好错误（含可复制粘贴的
    # 修复代码片段，提示用户用什么环境变量名）。
    #
    # @raise [ConfigurationError]
    def ensure_configured!
      return if @provider.configured?

      missing = @provider.configuration_requirements.reject { |req| @config.send(req) }
      config_block = <<~RUBY
        RubyLLM.configure do |config|
          #{missing.map { |key| "config.#{key} = ENV['#{key.to_s.upcase}']" }.join("\n  ")}
        end
      RUBY

      raise ConfigurationError,
            "#{@provider.name} provider is not configured. Add this to your initialization:\n\n#{config_block}"
    end
  end
end
