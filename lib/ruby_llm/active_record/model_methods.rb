# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/module/delegation'

module RubyLLM
  module ActiveRecord
    # Methods mixed into model registry models.
    #
    # `acts_as_model` 注入到 Model AR 类的方法。
    #
    # 启用 acts_as 后，模型注册表（默认是内置 models.json）会被持久化
    # 到数据库的 Model 表里，便于：
    # - 在 UI 中编辑/扩展模型元数据
    # - 跨多个 Rails 进程共享一份配置
    # - 把客户私有/微调的模型加入注册
    #
    # `to_llm` 把 AR 行还原为 RubyLLM::Model::Info 对象，使下层代码
    # 可以与 JSON 模式无缝互换。
    module ModelMethods
      extend ActiveSupport::Concern

      class_methods do # rubocop:disable Metrics/BlockLength
        # 触发一次远程刷新：先调用 RubyLLM 全局的 `refresh!`（拉取
        # provider 列表 + models.dev），再把内存数据写回 DB。
        def refresh!
          RubyLLM.models.refresh!

          save_to_database
        end

        # 把当前 RubyLLM.models 的全部模型 upsert 到本表。事务内进行
        # 以保证一致性（要么全成功，要么全回滚）。
        def save_to_database
          transaction do
            RubyLLM.models.all.each do |model_info|
              model = find_or_initialize_by(
                model_id: model_info.id,
                provider: model_info.provider
              )
              model.update!(from_llm_attributes(model_info))
            end
          end
        end

        # 把 Model::Info 转成新的 AR 实例（不保存）。
        def from_llm(model_info)
          new(from_llm_attributes(model_info))
        end

        private

        # Info → AR 列的属性映射。
        def from_llm_attributes(model_info)
          {
            model_id: model_info.id,
            name: model_info.name,
            provider: model_info.provider,
            family: model_info.family,
            model_created_at: model_info.created_at,
            context_window: model_info.context_window,
            max_output_tokens: model_info.max_output_tokens,
            knowledge_cutoff: model_info.knowledge_cutoff,
            modalities: model_info.modalities.to_h,
            capabilities: model_info.capabilities,
            pricing: model_info.pricing.to_h,
            metadata: model_info.metadata
          }
        end
      end

      # AR 行 → RubyLLM::Model::Info（用于 `Models.find` 内部）。
      # JSON 列在 AR 中存为字符串 key 的 Hash，这里 deep_symbolize_keys
      # 还原为符号 key（与 models.json 加载路径一致）。
      def to_llm
        RubyLLM::Model::Info.new(
          id: model_id,
          name: name,
          provider: provider,
          family: family,
          created_at: model_created_at,
          context_window: context_window,
          max_output_tokens: max_output_tokens,
          knowledge_cutoff: knowledge_cutoff,
          modalities: modalities&.deep_symbolize_keys || {},
          capabilities: capabilities,
          pricing: pricing&.deep_symbolize_keys || {},
          metadata: metadata&.deep_symbolize_keys || {}
        )
      end

      delegate :supports?, :supports_vision?, :supports_functions?, :type,
               :input_price_per_million, :output_price_per_million,
               :cache_read_input_price_per_million, :cache_write_input_price_per_million,
               :cached_input_price_per_million, :cache_creation_input_price_per_million,
               :function_calling?, :structured_output?, :batch?,
               :reasoning?, :citations?, :streaming?, :provider_class, :label,
               :cost_for,
               to: :to_llm
    end
  end
end
