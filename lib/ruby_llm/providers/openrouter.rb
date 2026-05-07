# frozen_string_literal: true

module RubyLLM
  module Providers
    # OpenRouter API integration.
    #
    # OpenRouter 是多家模型的聚合代理，OpenAI 兼容协议。错误响应中
    # 常嵌套上游 provider 的原始错误（在 `error.metadata.raw` 里），
    # 因此这里覆盖 `parse_error` 把"OpenRouter 消息 - 上游消息"拼接
    # 输出，便于排查上游真实问题。
    class OpenRouter < OpenAI
      include OpenRouter::Chat
      include OpenRouter::Models
      include OpenRouter::Streaming
      include OpenRouter::Images

      def api_base
        @config.openrouter_api_base || 'https://openrouter.ai/api/v1'
      end

      def headers
        {
          'Authorization' => "Bearer #{@config.openrouter_api_key}"
        }
      end

      # 兼容 hash / 数组的错误响应（OpenRouter 偶尔返回数组）。
      def parse_error(response)
        return if response.body.empty?

        body = try_parse_json(response.body)
        case body
        when Hash
          parse_error_part_message body
        when Array
          body.map do |part|
            parse_error_part_message part
          end.join('. ')
        else
          body
        end
      end

      private

      # 拼装"OpenRouter 错误消息 - 上游 provider 错误消息"。
      def parse_error_part_message(part)
        message = part.dig('error', 'message')
        raw = try_parse_json(part.dig('error', 'metadata', 'raw'))
        return message unless raw.is_a?(Hash)

        raw_message = raw.dig('error', 'message')
        return [message, raw_message].compact.join(' - ') if raw_message

        message
      end

      class << self
        def configuration_options
          %i[openrouter_api_key openrouter_api_base]
        end

        def configuration_requirements
          %i[openrouter_api_key]
        end
      end
    end
  end
end
