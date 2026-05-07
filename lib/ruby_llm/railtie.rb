# frozen_string_literal: true

# =============================================================================
# Rails 集成入口（仅在检测到 Rails 时定义）。
#
# 三件事：
# 1. 注册 'RubyLLM' 缩略词（让 Rails inflector 不会把它转成 'Ruby_llm'）。
# 2. 在 ActiveRecord 加载完成后注入 acts_as_* DSL —— 根据配置项
#    `use_new_acts_as` 决定加载新版还是旧版（旧版会发 deprecation 警告）。
# 3. 注册 rake 任务 `ruby_llm:load_models`。
# =============================================================================
if defined?(Rails::Railtie)
  module RubyLLM
    # Rails integration for RubyLLM
    class Railtie < Rails::Railtie
      initializer 'ruby_llm.inflections' do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym 'RubyLLM'
        end
      end

      initializer 'ruby_llm.active_record' do
        ActiveSupport.on_load :active_record do
          require 'ruby_llm/active_record/payload_helpers'
          require 'ruby_llm/active_record/chat_methods'
          require 'ruby_llm/active_record/message_methods'
          require 'ruby_llm/active_record/model_methods'
          require 'ruby_llm/active_record/tool_call_methods'

          if RubyLLM.config.use_new_acts_as
            require 'ruby_llm/active_record/acts_as'
            ::ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs
          else
            require 'ruby_llm/active_record/acts_as_legacy'
            ::ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAsLegacy

            Rails.logger.warn(
              "\n!!! RubyLLM's legacy acts_as API is deprecated and will be removed in RubyLLM 2.0.0. " \
              "Please consult the migration guide at https://rubyllm.com/upgrading-to-1-7/\n"
            )
          end
        end
      end

      rake_tasks do
        load 'tasks/ruby_llm.rake'
      end
    end
  end
end
