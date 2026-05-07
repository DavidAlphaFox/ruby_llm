# frozen_string_literal: true

module RubyLLM
  # Model-related classes for working with LLM models
  #
  # 模型元数据相关类的命名空间。
  #
  # 主要成员：
  # - {Model::Info} —— 单个模型的完整元数据（id、provider、context、
  #   modalities、capabilities、pricing 等）
  # - {Model::Modalities} —— 输入/输出模态
  # - {Model::Pricing} / {Model::PricingCategory} / {Model::PricingTier}
  #   —— 分层的价格表
  module Model
  end
end
