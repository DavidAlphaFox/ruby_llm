# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require_relative '../generator_helpers'

module RubyLLM
  module Generators
    # Generator to add v1.9 columns (cached tokens + raw content support) to existing apps.
    #
    # 升级迁移：在 messages 表新增 `cached_tokens` /
    # `cache_creation_tokens` / `content_raw` 列以支持 prompt 缓存
    # 计费与原生 payload 持久化。
    class UpgradeToV19Generator < Rails::Generators::Base
      include Rails::Generators::Migration
      include RubyLLM::Generators::GeneratorHelpers

      namespace 'ruby_llm:upgrade_to_v1_9'
      source_root File.expand_path('templates', __dir__)

      argument :model_mappings, type: :array, default: [], banner: 'message:MessageName'

      desc 'Adds cached token columns and raw content storage fields introduced in v1.9.0'

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_migration_file
        parse_model_mappings

        migration_template 'add_v1_9_message_columns.rb.tt',
                           'db/migrate/add_ruby_llm_v1_9_columns.rb',
                           migration_version: migration_version,
                           message_table_name: message_table_name
      end

      def show_next_steps
        say_status :success, 'Upgrade prepared!', :green
        say <<~INSTRUCTIONS

          Next steps:
          1. Review the generated migration
          2. Run: bin/rails db:migrate
          3. Restart your application server

          📚 See the v1.9.0 release notes for details on cached token tracking and raw content support.

        INSTRUCTIONS
      end
    end
  end
end
