# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Normalizes temperature for OpenAI models with provider-specific requirements.
      #
      # 把用户给的温度值归一化为对应模型可接受的形式：
      # - **o-系列、gpt-5**：必须 temperature=1.0，否则发请求会被拒
      # - **`*-search`**：不接受 temperature 参数，需置为 nil 删除
      # - 其他：原样透传
      module Temperature
        module_function

        # @param temperature [Float, nil]
        # @param model_id [String]
        # @return [Float, nil]
        def normalize(temperature, model_id)
          if model_id.match?(/^(o\d|gpt-5)/) && !temperature.nil? && !temperature_close_to_one?(temperature)
            RubyLLM.logger.debug { "Model #{model_id} requires temperature=1.0, setting that instead." }
            1.0
          elsif model_id.include?('-search')
            RubyLLM.logger.debug { "Model #{model_id} does not accept temperature parameter, removing" }
            nil
          else
            temperature
          end
        end

        # 浮点近似相等（用 EPSILON 防止 0.99999 被误判为非 1.0）。
        def temperature_close_to_one?(temperature)
          (temperature.to_f - 1.0).abs <= Float::EPSILON
        end
      end
    end
  end
end
