# frozen_string_literal: true

module RubyLLM
  module Providers
    # AWS Bedrock Converse API integration.
    #
    # AWS Bedrock 提供 Anthropic / Mistral / Meta / Amazon 自家等多家
    # 模型的统一入口。该 provider 走 **Converse API**（与 Anthropic
    # 直连协议**不同**），认证用 AWS SigV4 签名（见 `Bedrock::Auth`），
    # 流式用 AWS 自定义二进制 `application/vnd.amazon.eventstream`
    # （见 `Bedrock::Streaming`）。
    class Bedrock < Provider
      include Bedrock::Auth
      include Bedrock::Chat
      include Bedrock::Media
      include Bedrock::Models
      include Bedrock::Streaming

      def api_base
        "https://bedrock-runtime.#{bedrock_region}.amazonaws.com"
      end

      # 认证不通过静态 header；每个请求都要 SigV4 重新签名（见 `signed_post`）。
      def headers
        {}
      end

      # 覆盖 complete 以做 params 归一化：把 RubyLLM 的 `top_k` 等
      # 字段挪到 Bedrock Converse API 的 `additionalModelRequestFields`。
      # rubocop:disable Metrics/ParameterLists
      def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil,
                   tool_prefs: nil, &)
        normalized_params = normalize_params(params, model:)

        super(
          messages,
          tools: tools,
          tool_prefs: tool_prefs,
          temperature: temperature,
          model: model,
          params: normalized_params,
          headers: headers,
          schema: schema,
          thinking: thinking,
          &
        )
      end
      # rubocop:enable Metrics/ParameterLists

      # AWS 错误响应字段名不一致（message / Message / error / __type
      # 都见过），逐个尝试。
      def parse_error(response)
        return if response.body.nil? || response.body.empty?

        body = try_parse_json(response.body)
        return body if body.is_a?(String)

        body['message'] || body['Message'] || body['error'] || body['__type'] || super
      end

      # 模型列表接口在另一个域名（bedrock 而非 bedrock-runtime），
      # 需要单独签名。
      def list_models
        response = signed_get(models_api_base, models_url)
        parse_list_models_response(response, slug, capabilities)
      end

      class << self
        def configuration_options
          %i[bedrock_api_key bedrock_secret_key bedrock_region bedrock_session_token]
        end

        def configuration_requirements
          %i[bedrock_api_key bedrock_secret_key bedrock_region]
        end
      end

      private

      def bedrock_region
        @config.bedrock_region
      end

      def sync_response(connection, payload, additional_headers = {})
        signed_post(connection, completion_url, payload, additional_headers)
      end

      def normalize_params(params, model:)
        normalized = RubyLLM::Utils.deep_symbolize_keys(params || {})
        additional_fields = normalized[:additionalModelRequestFields] || {}

        top_k = normalized.delete(:top_k)
        if !top_k.nil? && model_supports_top_k?(model)
          additional_fields = RubyLLM::Utils.deep_merge(additional_fields, { top_k: top_k })
        end

        normalized[:additionalModelRequestFields] = additional_fields unless additional_fields.empty?
        normalized
      end

      def model_supports_top_k?(model)
        Bedrock::Models.reasoning_embedded?(model)
      end

      def api_payload(payload)
        cleaned = RubyLLM::Utils.deep_symbolize_keys(RubyLLM::Utils.deep_dup(payload))
        cleaned.delete(:tools)
        cleaned
      end
    end
  end
end
