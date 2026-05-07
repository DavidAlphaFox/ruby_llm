# frozen_string_literal: true

module RubyLLM
  module Providers
    # Google Vertex AI implementation
    #
    # Vertex AI 是 Gemini 的企业版（GCP 域名 + IAM 鉴权 + region/global
    # 端点）。继承 Gemini 复用大部分协议格式，覆盖：base url（含 location）、
    # 鉴权（OAuth bearer token，由 googleauth gem 颁发）。
    class VertexAI < Gemini
      include VertexAI::Chat
      include VertexAI::Streaming
      include VertexAI::Embeddings
      include VertexAI::Models
      include VertexAI::Transcription

      # OAuth scope；同时声明两个，部分 Vertex 端点需要 retriever scope。
      SCOPES = [
        'https://www.googleapis.com/auth/cloud-platform',
        'https://www.googleapis.com/auth/generative-language.retriever'
      ].freeze

      def initialize(config)
        super
        # @authorizer 延迟初始化（避免在不需要鉴权的场景加载 googleauth）。
        @authorizer = nil
      end

      def api_base
        if @config.vertexai_location.to_s == 'global'
          'https://aiplatform.googleapis.com/v1beta1'
        else
          "https://#{@config.vertexai_location}-aiplatform.googleapis.com/v1beta1"
        end
      end

      # 每次取 headers 都通过 authorizer 取一个有效的 OAuth token。
      # VCR 测试场景下用固定 token，避免 cassette 中残留真实凭据。
      def headers
        if defined?(VCR) && !VCR.current_cassette.recording?
          { 'Authorization' => 'Bearer test-token' }
        else
          initialize_authorizer unless @authorizer
          @authorizer.apply({})
        end
      rescue Google::Auth::AuthorizationError => e
        raise UnauthorizedError.new(nil, "Invalid Google Cloud credentials for Vertex AI: #{e.message}")
      end

      class << self
        def configuration_options
          %i[vertexai_project_id vertexai_location vertexai_service_account_key]
        end

        def configuration_requirements
          %i[vertexai_project_id vertexai_location]
        end
      end

      private

      # 优先用 service account JSON（用户在 config 中显式给出），
      # 否则退回 GCP "application default credentials"（GCE 元数据
      # 服务、gcloud CLI 缓存等）。
      def initialize_authorizer
        require 'googleauth'
        @authorizer =
          if @config.vertexai_service_account_key
            ::Google::Auth::ServiceAccountCredentials.make_creds(
              json_key_io: StringIO.new(@config.vertexai_service_account_key),
              scope: SCOPES
            )
          else
            ::Google::Auth.get_application_default(SCOPES)
          end
      rescue LoadError
        raise Error,
              'The googleauth gem ~> 1.15 is required for Vertex AI. Please add it to your Gemfile: gem "googleauth"'
      end
    end
  end
end
