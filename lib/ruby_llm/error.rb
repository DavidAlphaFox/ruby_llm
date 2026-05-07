# frozen_string_literal: true

module RubyLLM
  # Custom error class that wraps API errors from different providers
  # into a consistent format with helpful error messages.
  #
  # 所有 HTTP 相关错误的基类。
  #
  # 实例同时持有原始的 Faraday `response`（便于在异常处理中查看
  # 状态码、headers、body），以及一个由 provider 定制的人类可读
  # `message`。
  class Error < StandardError
    # 触发本异常的原始 HTTP 响应。可能为 nil（用户手动构造场景）。
    # @return [Faraday::Response, nil]
    attr_reader :response

    # 兼容两种调用形态：
    # - `Error.new('msg')`：仅传消息
    # - `Error.new(response, 'msg')`：传响应 + 消息
    def initialize(response = nil, message = nil)
      if response.is_a?(String)
        message = response
        response = nil
      end

      @response = response
      super(message || response&.body)
    end
  end

  # ---------------------------------------------------------------------------
  # 非 HTTP 错误（本地配置 / 校验问题）
  # ---------------------------------------------------------------------------

  # provider 配置不全（缺 API key 等）。
  class ConfigurationError < StandardError; end
  # Agent 引用的 ERB prompt 文件不存在。
  class PromptNotFoundError < StandardError; end
  # 消息 role 非法（必须是 :system/:user/:assistant/:tool）。
  class InvalidRoleError < StandardError; end
  # 工具选择参数非法（不在 `:auto/:none/:required/<工具名>` 之列）。
  class InvalidToolChoiceError < StandardError; end
  # 模型 ID 在注册表中不存在（且未启用 `assume_model_exists`）。
  class ModelNotFoundError < StandardError; end
  # 当前模型/provider 不支持给定的附件类型。
  class UnsupportedAttachmentError < StandardError; end

  # ---------------------------------------------------------------------------
  # HTTP 状态码对应的错误（按状态码精细划分，便于上层针对性 rescue）
  # ---------------------------------------------------------------------------

  class BadRequestError < Error; end           # 400
  class ForbiddenError < Error; end            # 403
  class ContextLengthExceededError < Error; end # 400/429（按消息文本判定）
  class OverloadedError < Error; end           # 529（Anthropic 等的"过载"专用码）
  class PaymentRequiredError < Error; end      # 402
  class RateLimitError < Error; end            # 429（不含上下文超长）
  class ServerError < Error; end               # 500
  class ServiceUnavailableError < Error; end   # 502/503/504
  class UnauthorizedError < Error; end         # 401

  # Faraday middleware that maps provider-specific API errors to RubyLLM errors.
  #
  # Faraday 中间件：把各家 provider 的 API 错误响应统一映射为 RubyLLM
  # 标准错误类型。
  #
  # 工作流程：在 `on_complete` 钩子中检查响应状态码，若非 2xx/3xx，
  # 则调用 `provider.parse_error(response)` 提取可读的错误消息，
  # 然后 raise 对应的 `RubyLLM::*Error`。
  #
  # 上下文超长的判定基于错误消息文本匹配（见 {CONTEXT_LENGTH_PATTERNS}），
  # 因为不同 provider 用 400 或 429 状态码报告该问题，但消息文本有
  # 可识别的模式。
  class ErrorMiddleware < Faraday::Middleware
    # @param app [#call] 下游中间件
    # @param options [Hash] 至少要包含 `:provider`
    def initialize(app, options = {})
      super(app)
      @provider = options[:provider]
    end

    # 中间件入口。透传请求，在响应完成后触发错误解析。
    def call(env)
      @app.call(env).on_complete do |response|
        self.class.parse_error(provider: @provider, response: response)
      end
    end

    class << self
      # 用于识别"上下文长度超限"的英文消息片段（不同家文案不同）。
      CONTEXT_LENGTH_PATTERNS = [
        /context length/i,
        /context window/i,
        /maximum context/i,
        /request too large/i,
        /too many tokens/i,
        /token count exceeds/i,
        /input[_\s-]?token/i,
        /input or output tokens? must be reduced/i,
        /reduce the length of messages/i
      ].freeze

      # 根据状态码与错误消息抛出最贴切的 RubyLLM 错误类型。
      #
      # @param provider [RubyLLM::Provider, nil] 用于调用 `parse_error`
      #   抽取友好消息
      # @param response [Faraday::Response] 待判定的响应
      # @return [String, nil] 当响应是 2xx/3xx 时返回消息（不抛错）
      # @raise [RubyLLM::Error] 对应状态码的子类
      def parse_error(provider:, response:) # rubocop:disable Metrics/PerceivedComplexity
        message = provider&.parse_error(response)

        case response.status
        when 200..399
          message
        when 400
          if context_length_exceeded?(message)
            raise ContextLengthExceededError.new(response, message || 'Context length exceeded')
          end

          raise BadRequestError.new(response, message || 'Invalid request - please check your input')
        when 401
          raise UnauthorizedError.new(response, message || 'Invalid API key - check your credentials')
        when 402
          raise PaymentRequiredError.new(response, message || 'Payment required - please top up your account')
        when 403
          raise ForbiddenError.new(response,
                                   message || 'Forbidden - you do not have permission to access this resource')
        when 429
          if context_length_exceeded?(message)
            raise ContextLengthExceededError.new(response, message || 'Context length exceeded')
          end

          raise RateLimitError.new(response, message || 'Rate limit exceeded - please wait a moment')
        when 500
          raise ServerError.new(response, message || 'API server error - please try again')
        when 502..504
          raise ServiceUnavailableError.new(response, message || 'API server unavailable - please try again later')
        when 529
          raise OverloadedError.new(response, message || 'Service overloaded - please try again later')
        else
          raise Error.new(response, message || 'An unknown error occurred')
        end
      end

      private

      # 是否疑似"上下文超限"错误。
      def context_length_exceeded?(message)
        return false if message.to_s.empty?

        CONTEXT_LENGTH_PATTERNS.any? { |pattern| message.match?(pattern) }
      end
    end
  end
end

# 把中间件以 `:llm_errors` 名注册到 Faraday，便于 Connection 通过
# `faraday.use :llm_errors, provider: @provider` 装配。
Faraday::Middleware.register_middleware(llm_errors: RubyLLM::ErrorMiddleware)
