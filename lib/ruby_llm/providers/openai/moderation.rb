# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Moderation methods of the OpenAI API integration
      #
      # OpenAI `/v1/moderations` 协议实现。直接把 `results` 数组传给
      # {RubyLLM::Moderation}（每项含 flagged/categories/category_scores）。
      module Moderation
        module_function

        def moderation_url
          'moderations'
        end

        def render_moderation_payload(input, model:)
          {
            model: model,
            input: input
          }
        end

        def parse_moderation_response(response, model:)
          data = response.body
          raise Error.new(response, data.dig('error', 'message')) if data.dig('error', 'message')

          RubyLLM::Moderation.new(
            id: data['id'],
            model: model,
            results: data['results'] || []
          )
        end
      end
    end
  end
end
