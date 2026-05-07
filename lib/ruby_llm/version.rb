# frozen_string_literal: true

# RubyLLM gem 版本号常量。
#
# 该文件由 `lib/ruby_llm.rb` 通过 `require_relative` 在启动时优先加载，
# 同时被 `ruby_llm.gemspec` 用于 `Gem::Specification#version`。
# 发版流程见 `lib/tasks/release.rake`。
module RubyLLM
  # 当前 gem 版本号（语义化版本字符串）。
  #
  # @return [String] 形如 `'1.15.0'` 的版本号字面量
  VERSION = '1.15.0'
end
