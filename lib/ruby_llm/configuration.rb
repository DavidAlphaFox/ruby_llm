# frozen_string_literal: true

module RubyLLM
  # Global configuration for RubyLLM
  #
  # RubyLLM 的全局配置容器。
  #
  # 设计要点：
  # 1. 通过类方法 `option(key, default)` 在类定义阶段元编程地注册配置项 ——
  #    自动生成 `attr_accessor`、记录默认值。
  # 2. 系统级配置项（默认模型、超时、重试、日志等）在本文件直接声明。
  # 3. **Provider 级配置项**（如 `openai_api_key`、`anthropic_api_key`）
  #    则由各 Provider 在 `lib/ruby_llm.rb` 调用 `Provider.register` 时通过
  #    `register_provider_options` 动态加入。
  # 4. `initialize` 时遍历所有默认值并赋给实例（lambda 默认值会被即时调用）。
  # 5. `instance_variables` 被刻意覆盖，过滤掉敏感字段（*_key、*_secret、
  #    *_token、*_id），避免日志/异常打印泄漏。
  class Configuration
    class << self
      # Declare a single configuration option.
      #
      # 声明一个配置项，等价于动态生成 `attr_accessor :key` 并把默认值
      # 登记到类级别的 `defaults` 表中。重复声明同一 key 会被忽略。
      #
      # @param key [Symbol, String] 配置项名
      # @param default [Object, Proc, nil] 默认值；若为 Proc 则在
      #   `initialize` 时通过 `instance_exec` 调用得到实际值
      # @return [void]
      def option(key, default = nil)
        key = key.to_sym
        return if options.include?(key)

        send(:attr_accessor, key)
        option_keys << key
        defaults[key] = default
      end

      # 批量注册一组 Provider 专属配置项（默认值统一为 nil）。
      #
      # 每个 Provider 在 `Provider.register` 时把自己声明的
      # `configuration_options` 数组传给该方法。
      #
      # @param options [Array<Symbol>] 待注册的键名
      # @return [void]
      def register_provider_options(options)
        Array(options).each { |key| option(key, nil) }
      end

      # 已注册的全部配置项键名快照。
      #
      # @return [Array<Symbol>]
      def options
        option_keys.dup
      end

      private

      # 内部存储：所有已注册的配置键。
      def option_keys = @option_keys ||= []
      # 内部存储：键 -> 默认值（Proc 或字面值）映射表。
      def defaults = @defaults ||= {}
      private :option
    end

    # System-level options are declared here.
    # Provider-specific options are declared in each provider class via
    # `self.configuration_options` and registered through Provider.register.
    #
    # 以下为系统级（与具体 provider 无关）配置项。
    # Provider 专属配置项（API key、organization id 等）在各 provider 类的
    # `configuration_options` 中声明，由 `Provider.register` 动态注入。

    # 默认聊天模型。可被 `Chat.new(model: ...)` 覆盖。
    option :default_model, 'gpt-5.4'
    # 默认 embedding 模型。
    option :default_embedding_model, 'text-embedding-3-small'
    # 默认审核模型（OpenAI Moderation）。
    option :default_moderation_model, 'omni-moderation-latest'
    # 默认图像生成模型。
    option :default_image_model, 'gpt-image-1.5'
    # 默认音频转写模型。
    option :default_transcription_model, 'whisper-1'

    # 内置模型注册表 JSON 文件路径（默认指向 gem 内置 models.json）。
    option :model_registry_file, -> { File.expand_path('models.json', __dir__) }
    # 当应用启用 acts_as 时，模型 ActiveRecord 类的常量名（默认 'Model'）。
    option :model_registry_class, 'Model'

    # 是否启用新版 acts_as_* DSL（旧版兼容开关，默认关闭）。
    option :use_new_acts_as, false

    # HTTP 请求超时时间（秒）。
    option :request_timeout, 300
    # 最大重试次数（Faraday Retry 中间件配置）。
    option :max_retries, 3
    # 初次重试间隔（秒）。
    option :retry_interval, 0.1
    # 重试间隔指数退避系数。
    option :retry_backoff_factor, 2
    # 重试间隔随机扰动比例（避免雪崩）。
    option :retry_interval_randomness, 0.5
    # HTTP 代理地址（如 'http://127.0.0.1:7890'）。
    option :http_proxy, nil

    # 自定义 logger；若为 nil，会使用 `log_file` + `log_level` 创建默认 logger。
    option :logger, nil
    # 默认日志输出目标，可以是 IO 对象或文件路径。
    option :log_file, -> { $stdout }
    # 日志等级，默认 INFO；设置环境变量 `RUBYLLM_DEBUG=1` 开启 DEBUG。
    option :log_level, -> { ENV['RUBYLLM_DEBUG'] ? Logger::DEBUG : Logger::INFO }
    # 是否对 SSE 流式 chunk 做逐块 debug 日志，默认关闭。
    option :log_stream_debug, -> { ENV['RUBYLLM_STREAM_DEBUG'] == 'true' }
    # 正则匹配超时（仅 Ruby 3.2+ 有 Regexp.timeout）；用于防御 ReDoS。
    option :log_regexp_timeout, -> { Regexp.respond_to?(:timeout) ? (Regexp.timeout || 1.0) : nil }

    # 用注册表中的所有默认值初始化实例。Proc 默认值会在此被求值。
    def initialize
      self.class.send(:defaults).each do |key, default|
        value = default.respond_to?(:call) ? instance_exec(&default) : default
        public_send("#{key}=", value)
      end
    end

    # 覆盖 `Object#instance_variables`：在 `inspect` / pry 输出中
    # **隐藏敏感字段**，凡是以 `_id`、`_key`、`_secret`、`_token` 结尾
    # 的实例变量都不会出现，避免 API key 被无意泄漏。
    #
    # @return [Array<Symbol>]
    def instance_variables
      super.reject { |ivar| ivar.to_s.match?(/_id|_key|_secret|_token$/) }
    end

    # 写入正则超时时间，并对低版本 Ruby 做兼容处理。
    #
    # @param value [Numeric, nil] 超时时间（秒）；nil 表示禁用
    # @return [Numeric, nil]
    def log_regexp_timeout=(value)
      if value.nil?
        @log_regexp_timeout = nil
      elsif Regexp.respond_to?(:timeout)
        @log_regexp_timeout = value
      else
        RubyLLM.logger.warn("log_regexp_timeout is not supported on Ruby #{RUBY_VERSION}")
        @log_regexp_timeout = value
      end
    end
  end
end
