# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/inflector'

module RubyLLM
  module ActiveRecord
    # Adds chat and message persistence capabilities to ActiveRecord models.
    #
    # ActsAs 是 RubyLLM 与 Rails ActiveRecord 集成的"主入口" concern。
    #
    # 提供 4 个类级 DSL，让用户用一行声明把 AR 模型变成 RubyLLM 的
    # 持久化承载：
    # - `acts_as_chat`  —— 把 Chat 表关联到 Messages
    # - `acts_as_message` —— 把 Message 表关联到 Chat / ToolCalls / Model
    # - `acts_as_tool_call` —— ToolCall 表关联 Message + 结果消息
    # - `acts_as_model` —— Model 注册表的 AR 持久化
    #
    # `included` 钩子做一件副作用：**monkey-patch** {RubyLLM::Models}，
    # 让 `load_models` 优先读 DB，失败/空时降级到 JSON。
    module ActsAs
      extend ActiveSupport::Concern

      # When ActsAs is included, ensure models are loaded from database
      def self.included(base)
        super
        # Monkey-patch Models to use database when ActsAs is active
        RubyLLM::Models.class_eval do
          # 覆盖默认实现：DB 优先，JSON 兜底。任何异常（表不存在、
          # 列类型不匹配等）都降级到 JSON，保证应用始终能启动。
          def self.load_models
            database_models = read_from_database
            return database_models if database_models.any?

            RubyLLM.logger.debug { 'Model registry is empty in database, falling back to JSON registry' }
            read_from_json
          rescue StandardError => e
            RubyLLM.logger.debug { "Failed to load models from database: #{e.message}, falling back to JSON" }
            read_from_json
          end

          # 从 `RubyLLM.config.model_registry_class` 指定的 AR 模型读
          # 全部行，转成 Model::Info 对象。
          def self.read_from_database
            model_class = RubyLLM.config.model_registry_class
            model_class = model_class.constantize if model_class.is_a?(String)
            return [] unless model_class.table_exists?

            model_class.all.map(&:to_llm)
          end

          # 强制从 DB 重新加载模型表（实例方法）。
          def load_from_database!
            @models = self.class.read_from_database
          end
        end
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        # 把当前 AR 类声明为"Chat"。
        #
        # 自动建立两个 Rails 关联：
        # - `has_many :messages`（按 `created_at` 升序）
        # - `belongs_to :model`（可选，模型注册表）
        #
        # 同时 include {ChatMethods}，注入 `ask` / `with_tool` / `complete`
        # 等所有 Chat DSL 的 AR 适配版本（数据库持久化 + 行为透传）。
        #
        # @param messages [Symbol] 关联名（默认 :messages）
        # @param message_class [String, nil] Message 类名，默认按
        #   association 名 classify 推断
        # @param messages_foreign_key [Symbol, nil] FK 列名
        # @param model [Symbol] 模型关联名，默认 :model
        # @param model_class [String, nil]
        # @param model_foreign_key [Symbol, nil]
        def acts_as_chat(messages: :messages, message_class: nil, messages_foreign_key: nil, # rubocop:disable Metrics/ParameterLists
                         model: :model, model_class: nil, model_foreign_key: nil)
          include RubyLLM::ActiveRecord::ChatMethods

          class_attribute :messages_association_name, :model_association_name, :message_class, :model_class

          self.messages_association_name = messages
          self.model_association_name = model
          self.message_class = (message_class || messages.to_s.classify).to_s
          self.model_class = (model_class || model.to_s.classify).to_s

          has_many messages,
                   -> { order(created_at: :asc) },
                   class_name: self.message_class,
                   foreign_key: messages_foreign_key,
                   dependent: :destroy

          belongs_to model,
                     class_name: self.model_class,
                     foreign_key: model_foreign_key,
                     optional: true

          define_method :messages_association do
            send(messages_association_name)
          end

          define_method :model_association do
            send(model_association_name)
          end

          define_method :'model_association=' do |value|
            send("#{model_association_name}=", value)
          end
        end

        # 把 AR 类声明为"模型注册表行"。
        #
        # 关键约束：
        # - `model_id` 在同一 `provider` 下唯一（避免重复）
        # - `provider` 与 `name` 必填
        # - `has_many :chats` —— 反向关联到使用该模型的 Chat
        #
        # include {ModelMethods} 后获得 `to_llm` / `refresh!` /
        # `from_llm` 等方法。
        def acts_as_model(chats: :chats, chat_class: nil, chats_foreign_key: nil)
          include RubyLLM::ActiveRecord::ModelMethods

          class_attribute :chats_association_name, :chat_class

          self.chats_association_name = chats
          self.chat_class = (chat_class || chats.to_s.classify).to_s

          validates :model_id, presence: true, uniqueness: { scope: :provider }
          validates :provider, presence: true
          validates :name, presence: true

          has_many chats, class_name: self.chat_class, foreign_key: chats_foreign_key

          define_method :chats_association do
            send(chats_association_name)
          end
        end

        # 把 AR 类声明为"Message"。
        #
        # 关联：
        # - `belongs_to :chat`（必填，可选 `touch:` 让 Chat 的
        #   updated_at 随消息更新）
        # - `has_many :tool_calls`
        # - `belongs_to :parent_tool_call`（自反 FK，用于 role=:tool 的
        #   消息指回触发它的工具调用）
        # - `has_many :tool_results`（through tool_calls，反向链回
        #   作为结果的 Message）
        # - `belongs_to :model`（可选）
        # - `delegate :tool_call?, :tool_result?, to: :to_llm`
        def acts_as_message(chat: :chat, chat_class: nil, chat_foreign_key: nil, touch_chat: false, # rubocop:disable Metrics/ParameterLists
                            tool_calls: :tool_calls, tool_call_class: nil, tool_calls_foreign_key: nil,
                            model: :model, model_class: nil, model_foreign_key: nil)
          include RubyLLM::ActiveRecord::MessageMethods

          class_attribute :chat_association_name, :tool_calls_association_name, :model_association_name,
                          :chat_class, :tool_call_class, :model_class

          self.chat_association_name = chat
          self.tool_calls_association_name = tool_calls
          self.model_association_name = model
          self.chat_class = (chat_class || chat.to_s.classify).to_s
          self.tool_call_class = (tool_call_class || tool_calls.to_s.classify).to_s
          self.model_class = (model_class || model.to_s.classify).to_s

          belongs_to chat,
                     class_name: self.chat_class,
                     foreign_key: chat_foreign_key,
                     touch: touch_chat

          has_many tool_calls,
                   class_name: self.tool_call_class,
                   foreign_key: tool_calls_foreign_key,
                   dependent: :destroy

          belongs_to :parent_tool_call,
                     class_name: self.tool_call_class,
                     foreign_key: ActiveSupport::Inflector.foreign_key(tool_calls.to_s.singularize),
                     optional: true

          has_many :tool_results,
                   through: tool_calls,
                   source: :result,
                   class_name: name

          belongs_to model,
                     class_name: self.model_class,
                     foreign_key: model_foreign_key,
                     optional: true

          delegate :tool_call?, :tool_result?, to: :to_llm

          define_method :chat_association do
            send(chat_association_name)
          end

          define_method :tool_calls_association do
            send(tool_calls_association_name)
          end

          define_method :model_association do
            send(model_association_name)
          end
        end

        # 把 AR 类声明为"ToolCall"。
        #
        # 关联：
        # - `belongs_to :message`（触发本次工具调用的 assistant 消息）
        # - `has_one :result`（关联到 role=:tool 的结果消息；通过同一
        #   AR 类自指实现，因为工具结果本身也是一条 Message）
        def acts_as_tool_call(message: :message, message_class: nil, message_foreign_key: nil, # rubocop:disable Metrics/ParameterLists
                              result: :result, result_class: nil, result_foreign_key: nil)
          include RubyLLM::ActiveRecord::ToolCallMethods

          class_attribute :message_association_name, :result_association_name, :message_class, :result_class

          self.message_association_name = message
          self.result_association_name = result
          self.message_class = (message_class || message.to_s.classify).to_s
          self.result_class = (result_class || self.message_class).to_s

          belongs_to message,
                     class_name: self.message_class,
                     foreign_key: message_foreign_key

          has_one result,
                  class_name: self.result_class,
                  foreign_key: result_foreign_key,
                  dependent: :nullify

          define_method :message_association do
            send(message_association_name)
          end

          define_method :result_association do
            send(result_association_name)
          end
        end
      end
    end
  end
end
