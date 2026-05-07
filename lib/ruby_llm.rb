# frozen_string_literal: true

require 'base64'
require 'event_stream_parser'
require 'faraday'
require 'faraday/multipart'
require 'faraday/retry'
require 'json'
require 'logger'
require 'marcel'
require 'securerandom'
require 'date'
require 'time'
require 'zeitwerk'

# =============================================================================
# 文件作用：RubyLLM gem 的入口文件。
#
# 本文件做四件事：
#   1. require 必需的标准库 / 第三方库（faraday、zeitwerk、marcel 等）
#   2. 配置 Zeitwerk 自动加载器（含特殊缩写大小写规则）
#   3. 定义 `RubyLLM` 顶层模块及其便捷类方法（chat/embed/paint/...）
#   4. 把 13 家 Provider 实现注册到 `Provider.providers` 注册表
#   5. 检测到 Rails 时加载 Railtie，启用 ActiveRecord 集成
#
# 整体架构请参考 docs/_advanced/architecture.md。
# =============================================================================

# Zeitwerk 自动加载器实例。
# 通过 inflector 显式声明常量大小写，避免 OpenAI、PDF、URL 等首字母缩写
# 被默认推断为 `Openai`、`Pdf`、`Url`。
loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  'azure' => 'Azure',
  'UI' => 'UI',
  'api' => 'API',
  'bedrock' => 'Bedrock',
  'deepseek' => 'DeepSeek',
  'gpustack' => 'GPUStack',
  'llm' => 'LLM',
  'mistral' => 'Mistral',
  'openai' => 'OpenAI',
  'openrouter' => 'OpenRouter',
  'pdf' => 'PDF',
  'perplexity' => 'Perplexity',
  'ruby_llm' => 'RubyLLM',
  'vertexai' => 'VertexAI',
  'xai' => 'XAI'
)
# 以下目录由其他机制加载（rake 任务、generators、Rails Railtie），
# 不应进入 Zeitwerk 的常量自动加载范围。
loader.ignore("#{__dir__}/tasks")
loader.ignore("#{__dir__}/generators")
loader.ignore("#{__dir__}/ruby_llm/active_record")
loader.ignore("#{__dir__}/ruby_llm/railtie.rb")
loader.setup

# A delightful Ruby interface to modern AI language models.
#
# RubyLLM 顶层模块 —— 面向最终用户的便捷入口。
#
# 提供链式 DSL（{RubyLLM.chat}）以及单次任务方法（{RubyLLM.embed} /
# {RubyLLM.paint} / {RubyLLM.moderate} / {RubyLLM.transcribe}）。
# 全部方法都委托给对应的核心类。
module RubyLLM
  # 该 gem 所有自定义异常的基类。
  # 具体子类型见 `lib/ruby_llm/error.rb`（如 `RateLimitError`、`UnauthorizedError`）。
  class Error < StandardError; end

  class << self
    # 创建一个隔离的 {Context}，可在块内临时覆盖配置项。
    #
    # @yieldparam context_config [RubyLLM::Configuration] 全局配置的副本
    # @return [RubyLLM::Context] 持有副本配置的上下文对象
    # @example
    #   ctx = RubyLLM.context { |c| c.request_timeout = 600 }
    #   ctx.chat.ask '...'
    def context
      context_config = config.dup
      yield context_config if block_given?
      Context.new(context_config)
    end

    # 创建一个 {Chat} 实例（多轮对话）。
    #
    # @param args [Array] 透传给 {Chat#initialize}
    # @return [RubyLLM::Chat]
    def chat(...)
      Chat.new(...)
    end

    # 生成文本嵌入向量。
    #
    # @param args [Array] 透传给 {Embedding.embed}
    # @return [RubyLLM::Embedding]
    def embed(...)
      Embedding.embed(...)
    end

    # 调用内容审核接口。
    #
    # @param args [Array] 透传给 {Moderation.moderate}
    # @return [RubyLLM::Moderation]
    def moderate(...)
      Moderation.moderate(...)
    end

    # 调用图像生成接口。
    #
    # @param args [Array] 透传给 {Image.paint}
    # @return [RubyLLM::Image]
    def paint(...)
      Image.paint(...)
    end

    # 调用语音转写接口。
    #
    # @param args [Array] 透传给 {Transcription.transcribe}
    # @return [RubyLLM::Transcription]
    def transcribe(...)
      Transcription.transcribe(...)
    end

    # 模型注册表（含 800+ 内置模型元数据）。
    #
    # @return [RubyLLM::Models] 单例对象
    def models
      Models.instance
    end

    # 已注册的 provider 类列表。
    #
    # @return [Array<Class>] 形如 `[RubyLLM::Providers::OpenAI, ...]`
    def providers
      Provider.providers.values
    end

    # 全局配置入口（块形式）。
    #
    # @yieldparam config [RubyLLM::Configuration]
    # @return [void]
    # @example
    #   RubyLLM.configure do |config|
    #     config.openai_api_key = ENV['OPENAI_API_KEY']
    #   end
    def configure
      yield config
    end

    # 取得（或惰性创建）全局 {Configuration} 单例。
    #
    # @return [RubyLLM::Configuration]
    def config
      @config ||= Configuration.new
    end

    # 取得（或惰性创建）gem 内部使用的 logger。
    # 若用户在 config.logger 中提供了自定义 logger，则直接复用。
    #
    # @return [Logger]
    def logger
      @logger ||= config.logger || Logger.new(
        config.log_file,
        progname: 'RubyLLM',
        level: config.log_level
      )
    end
  end
end

# -----------------------------------------------------------------------------
# Provider 注册：把 13 家 Provider 实现按 slug 注册到 Provider.providers。
# 这一步必须在 module RubyLLM 定义完成之后，railtie 加载之前完成，
# 因为 railtie 与默认配置在初始化时会读取注册表。
# -----------------------------------------------------------------------------
RubyLLM::Provider.register :anthropic, RubyLLM::Providers::Anthropic
RubyLLM::Provider.register :azure, RubyLLM::Providers::Azure
RubyLLM::Provider.register :bedrock, RubyLLM::Providers::Bedrock
RubyLLM::Provider.register :deepseek, RubyLLM::Providers::DeepSeek
RubyLLM::Provider.register :gemini, RubyLLM::Providers::Gemini
RubyLLM::Provider.register :gpustack, RubyLLM::Providers::GPUStack
RubyLLM::Provider.register :mistral, RubyLLM::Providers::Mistral
RubyLLM::Provider.register :ollama, RubyLLM::Providers::Ollama
RubyLLM::Provider.register :openai, RubyLLM::Providers::OpenAI
RubyLLM::Provider.register :openrouter, RubyLLM::Providers::OpenRouter
RubyLLM::Provider.register :perplexity, RubyLLM::Providers::Perplexity
RubyLLM::Provider.register :vertexai, RubyLLM::Providers::VertexAI
RubyLLM::Provider.register :xai, RubyLLM::Providers::XAI

# 仅在 Rails 环境下加载 Railtie（启用生成器、acts_as_*、自动重载）。
require 'ruby_llm/railtie' if defined?(Rails::Railtie)
