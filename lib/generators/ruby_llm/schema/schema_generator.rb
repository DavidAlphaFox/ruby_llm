# frozen_string_literal: true

require 'rails/generators'

module RubyLLM
  module Generators
    # Generator for RubyLLM schema classes.
    #
    # `bin/rails g ruby_llm:schema <Name>` —— 在 `app/schemas/` 下生成
    # 一个 RubyLLM::Schema 子类骨架（自动追加 `Schema` 后缀）。
    class SchemaGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      namespace 'ruby_llm:schema'

      desc 'Creates a RubyLLM schema class'

      def create_schema_file
        template 'schema.rb.tt', File.join('app/schemas', class_path, "#{file_name}.rb")
      end

      private

      def schema_class_name
        class_name.end_with?('Schema') ? class_name : "#{class_name}Schema"
      end
    end
  end
end
