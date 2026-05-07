# frozen_string_literal: true

module RubyLLM
  # Holds per-call configs
  #
  # 一次性、局部化的配置上下文。
  #
  # `Context` 用于在不污染全局 `RubyLLM.config` 的前提下，临时覆盖
  # 一组配置（例如换一个 API key、换一个超时时间），并在该上下文中
  # 创建 Chat / Embedding / Image 等任务对象。
  #
  # 典型用法：
  #
  #   ctx = RubyLLM.context do |c|
  #     c.openai_api_key = 'sk-xxx'
  #     c.request_timeout = 600
  #   end
  #   ctx.chat.ask '你好'
  #
  # 创建方式见 `RubyLLM.context`（lib/ruby_llm.rb），它会复制全局配置
  # 后传入构造函数。
  class Context
    # 该上下文持有的配置对象（`Configuration` 的副本）。
    #
    # @return [RubyLLM::Configuration]
    attr_reader :config

    # 初始化上下文。
    #
    # @param config [RubyLLM::Configuration] 复制后的配置对象
    def initialize(config)
      @config = config
      @connections = {}
    end

    # 创建一个绑定到当前上下文的 Chat 实例。
    #
    # @param args [Array] 透传给 {Chat#initialize} 的位置参数
    # @param kwargs [Hash] 透传给 {Chat#initialize} 的关键字参数
    # @return [RubyLLM::Chat]
    def chat(*args, **kwargs, &)
      Chat.new(*args, **kwargs, context: self, &)
    end

    # 在当前上下文中执行一次 embedding 任务。
    #
    # @param args [Array] 透传给 {Embedding.embed}
    # @param kwargs [Hash] 透传给 {Embedding.embed}
    # @return [RubyLLM::Embedding] 包含向量的结果对象
    def embed(*args, **kwargs, &)
      Embedding.embed(*args, **kwargs, context: self, &)
    end

    # 在当前上下文中执行一次图像生成任务。
    #
    # @param args [Array] 透传给 {Image.paint}
    # @param kwargs [Hash] 透传给 {Image.paint}
    # @return [RubyLLM::Image]
    def paint(*args, **kwargs, &)
      Image.paint(*args, **kwargs, context: self, &)
    end

    # 取得给定 provider 实例对应的 Faraday 连接。
    #
    # 当前实现直接返回 provider 自带的连接；保留该方法是为了
    # 未来在上下文层做连接复用（缓存到 `@connections`）。
    #
    # @param provider_instance [RubyLLM::Provider]
    # @return [RubyLLM::Connection]
    def connection_for(provider_instance)
      provider_instance.connection
    end
  end
end
