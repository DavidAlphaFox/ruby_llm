# frozen_string_literal: true

require 'erb'
require 'forwardable'
require 'pathname'
require 'ruby_llm/schema'

module RubyLLM
  # Base class for simple, class-configured agents.
  #
  # 可继承的 Agent 模板基类。
  #
  # `Agent` 在 `Chat` 之上提供"类级 DSL + 实例转发"的封装：
  # 你在子类用 `model / instructions / tools / schema / temperature` 等
  # 类方法**声明**配置，构造实例时这些声明会被一次性应用到内部的
  # `Chat`（或 ActiveRecord 持久化的 chat 记录）上。
  #
  # 关键设计：
  # - **类级配置继承**：`inherited` 钩子把父类的 DSL 配置复制到子类，
  #   保证子类化时不丢配置。
  # - **动态配置（Proc / 实例方法）**：所有 DSL 方法都接受 block，
  #   `block` 在 "运行时上下文" 内 `instance_exec` —— 该上下文持有
  #   `chat` 引用与所有声明的 inputs，可像调用方法一样访问输入参数，
  #   或调用 `prompt(:name)` 渲染 ERB prompt 文件。
  # - **inputs 与 chat 选项分离**：`partition_inputs` 把调用方传入的
  #   kwargs 拆成"声明过的 inputs"与"透传给 Chat 的选项"。
  # - **持久化模式**：通过 `chat_model` 指定 AR 模型类后，可用
  #   `create / find / sync_instructions!` 在 DB 中操作 chat 记录。
  # - **instance** 通过 `Forwardable` 把所有常用 `Chat` 方法直接
  #   转发到 `@chat`，使 Agent 的实例 API 与 Chat 几乎等价。
  #
  # 典型用法：
  #
  #   class WeatherAssistant < RubyLLM::Agent
  #     model 'gpt-5-nano'
  #     instructions 'Be concise.'
  #     tools Weather
  #   end
  #
  #   WeatherAssistant.new.ask 'Berlin?'
  class Agent
    extend Forwardable
    include Enumerable

    class << self
      # 子类继承钩子：把父类的 DSL 配置（chat_kwargs / tools /
      # instructions / temperature / ...）**深拷贝**到子类，
      # 保证子类化的修改不影响父类。
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@chat_kwargs, (@chat_kwargs || {}).dup)
        subclass.instance_variable_set(:@tools, (@tools || []).dup)
        subclass.instance_variable_set(:@instructions, @instructions)
        subclass.instance_variable_set(:@temperature, @temperature)
        subclass.instance_variable_set(:@thinking, @thinking)
        subclass.instance_variable_set(:@params, (@params || {}).dup)
        subclass.instance_variable_set(:@headers, (@headers || {}).dup)
        subclass.instance_variable_set(:@schema, @schema)
        subclass.instance_variable_set(:@context, @context)
        subclass.instance_variable_set(:@chat_model, @chat_model)
        subclass.instance_variable_set(:@input_names, (@input_names || []).dup)
      end

      # 声明该 Agent 默认使用的模型。
      #
      # @param model_id [String, nil] 模型 ID 或别名
      # @param options [Hash] 透传给 `RubyLLM.chat` 的其他关键字参数
      #   （如 `provider:`、`assume_model_exists:`）
      # @return [Hash] 当前的 chat_kwargs
      def model(model_id = nil, **options)
        options[:model] = model_id unless model_id.nil?
        @chat_kwargs = options
      end

      # 声明该 Agent 注册的工具集。可以传工具类列表，或一个 block ——
      # block 会在运行时上下文中求值，按需返回工具数组。
      #
      # 不带参数调用时返回当前已声明的工具。
      #
      # @return [Array<Class>, Proc]
      def tools(*tools, &block)
        return @tools || [] if tools.empty? && !block_given?

        @tools = block_given? ? block : tools.flatten
      end

      # 声明 system 指令。三种形态：
      #   1. 纯文本：`instructions 'Be concise.'`
      #   2. ERB prompt 文件：`instructions :greeting, name: -> { current_user.name }`
      #      —— 会在 `app/prompts/<agent_path>/greeting.txt.erb` 寻找模板
      #   3. block：在运行时上下文求值得到字符串
      #
      # @return [String, Hash, Proc]
      def instructions(text = nil, **prompt_locals, &block)
        if text.nil? && prompt_locals.empty? && !block_given?
          @instructions ||= { prompt: 'instructions', locals: {} }
          return @instructions
        end

        @instructions = block || text || { prompt: 'instructions', locals: prompt_locals }
      end

      # 声明默认温度；不带参数返回当前值。
      def temperature(value = nil)
        return @temperature if value.nil?

        @temperature = value
      end

      # 声明扩展思考预算。
      def thinking(effort: nil, budget: nil)
        return @thinking if effort.nil? && budget.nil?

        @thinking = { effort: effort, budget: budget }
      end

      # 声明透传给 provider 的额外参数（接受 hash 或 block）。
      def params(**params, &block)
        return @params || {} if params.empty? && !block_given?

        @params = block_given? ? block : params
      end

      # 声明额外 HTTP 请求头（接受 hash 或 block）。
      def headers(**headers, &block)
        return @headers || {} if headers.empty? && !block_given?

        @headers = block_given? ? block : headers
      end

      # 声明结构化输出 schema（类、实例、hash 或 block）。
      def schema(value = nil, &block)
        return @schema if value.nil? && !block_given?

        @schema = block_given? ? block : value
      end

      # 声明绑定的 Context（局部配置）。
      def context(value = nil)
        return @context if value.nil?

        @context = value
      end

      # 绑定 ActiveRecord 持久化的 Chat 模型类（类常量或字符串）。
      # 修改该值会清空缓存的解析结果。
      def chat_model(value = nil)
        return @chat_model if value.nil?

        @chat_model = value
        remove_instance_variable(:@resolved_chat_model) if instance_variable_defined?(:@resolved_chat_model)
      end

      # 声明该 Agent 接受的输入参数名列表。`Agent.new(name: ...)` 调用时
      # 这些 key 会被识别为 input（其余 kwargs 透传给 Chat）。
      def inputs(*names)
        return @input_names || [] if names.empty?

        @input_names = names.flatten.map(&:to_sym)
      end

      # 当前的 chat_kwargs 副本（即 `model` DSL 收集的所有选项）。
      def chat_kwargs
        @chat_kwargs || {}
      end

      # 直接生成一个配置好的 RubyLLM::Chat 实例（不创建 Agent 实例）。
      #
      # @param kwargs [Hash] 可包含 inputs 与 Chat 选项；自动分离
      # @return [RubyLLM::Chat]
      def chat(**kwargs)
        input_values, chat_options = partition_inputs(kwargs)
        chat = RubyLLM.chat(**chat_kwargs, **chat_options)
        apply_configuration(chat, input_values:, persist_instructions: true)
        chat
      end

      # 通过 `chat_model.create(...)` 创建 AR 持久化的 Chat 记录，
      # 并应用 Agent 配置。
      def create(**kwargs)
        with_rails_chat_record(:create, **kwargs)
      end

      # `create` 的 bang 版本（保存失败时抛错）。
      def create!(**kwargs)
        with_rails_chat_record(:create!, **kwargs)
      end

      # 加载已有的 AR Chat 记录并应用 Agent 配置（不持久化指令）。
      #
      # @param id [Object] AR 记录主键
      # @return [Object] AR Chat 记录
      def find(id, **kwargs)
        raise ArgumentError, 'chat_model must be configured to use find' unless resolved_chat_model

        input_values, = partition_inputs(kwargs)
        record = resolved_chat_model.find(id)
        apply_configuration(record, input_values:, persist_instructions: false)

        record
      end

      # 把 Agent 当前声明的 instructions **同步**到指定的 Chat 记录上
      # （用于 instructions 文案变化后批量回写到既有 chat）。
      #
      # @param chat_or_id [Object, Integer] AR 记录或主键
      # @return [Object] AR Chat 记录
      def sync_instructions!(chat_or_id, **kwargs)
        raise ArgumentError, 'chat_model must be configured to use sync_instructions!' unless resolved_chat_model

        input_values, = partition_inputs(kwargs)
        record = chat_or_id.is_a?(resolved_chat_model) ? chat_or_id : resolved_chat_model.find(chat_or_id)
        apply_assume_model_exists(record)
        runtime = runtime_context(chat: record, inputs: input_values)
        instructions_value = resolved_instructions_value(record, runtime, inputs: input_values)
        return record if instructions_value.nil?

        record.with_instructions(instructions_value)
        record
      end

      # 渲染指定名称的 ERB prompt 文件。
      #
      # @param name [Symbol, String] prompt 名（不带扩展名）
      # @param chat [Object] 当前 chat 引用（注入 ERB locals）
      # @param inputs [Hash] 当前 inputs（注入 ERB locals）
      # @param locals [Hash] 额外 locals（值可为 Proc，运行时上下文求值）
      # @return [String] 渲染结果
      # @raise [RubyLLM::PromptNotFoundError]
      def render_prompt(name, chat:, inputs:, locals:)
        path = prompt_path_for(name)
        unless File.exist?(path)
          raise RubyLLM::PromptNotFoundError,
                "Prompt file not found for #{self}: #{path}. Create the file or use inline instructions."
        end

        resolved_locals = resolve_prompt_locals(locals, runtime: runtime_context(chat:, inputs:), chat:, inputs:)
        ERB.new(File.read(path)).result_with_hash(resolved_locals)
      end

      private

      # 在 AR Chat 模型上调用 `create` 或 `create!`，并应用 Agent 配置。
      #
      # @param method_name [Symbol] `:create` 或 `:create!`
      # @return [Object, nil]
      def with_rails_chat_record(method_name, **kwargs)
        raise ArgumentError, 'chat_model must be configured to use create/create!' unless resolved_chat_model

        input_values, chat_options = partition_inputs(kwargs)
        record = resolved_chat_model.public_send(method_name, **chat_kwargs, **chat_options)
        apply_configuration(record, input_values:, persist_instructions: true) if record
        record
      end

      # 把当前 Agent 类的全部 DSL 声明依次应用到 chat_object 上。
      #
      # @param chat_object [RubyLLM::Chat, Object] 真实的 Chat，
      #   或 AR 包装对象（含 `to_llm` 方法）
      # @param input_values [Hash] 已分离出来的 inputs
      # @param persist_instructions [Boolean] 指令是否需要持久化
      #   （AR 模式下 instructions 通常存进 messages 表）
      def apply_configuration(chat_object, input_values:, persist_instructions:)
        runtime = runtime_context(chat: chat_object, inputs: input_values)
        llm_chat = llm_chat_for(chat_object)

        apply_context(llm_chat)
        apply_instructions(chat_object, runtime, inputs: input_values, persist: persist_instructions)
        apply_tools(llm_chat, runtime)
        apply_temperature(llm_chat)
        apply_thinking(llm_chat)
        apply_params(llm_chat, runtime)
        apply_headers(llm_chat, runtime)
        apply_schema(llm_chat, runtime)
      end

      def apply_context(llm_chat)
        llm_chat.with_context(context) if context
      end

      def apply_instructions(chat_object, runtime, inputs:, persist:)
        value = resolved_instructions_value(chat_object, runtime, inputs:)
        return if value.nil?

        target = instruction_target(chat_object, persist:)
        return target.with_runtime_instructions(value) if use_runtime_instructions?(target, persist:)

        target.with_instructions(value)
      end

      def apply_tools(llm_chat, runtime)
        tools_to_apply = Array(evaluate(tools, runtime))
        llm_chat.with_tools(*tools_to_apply) unless tools_to_apply.empty?
      end

      def apply_temperature(llm_chat)
        llm_chat.with_temperature(temperature) unless temperature.nil?
      end

      def apply_thinking(llm_chat)
        llm_chat.with_thinking(**thinking) if thinking
      end

      def apply_params(llm_chat, runtime)
        value = evaluate(params, runtime)
        llm_chat.with_params(**value) if value && !value.empty?
      end

      def apply_headers(llm_chat, runtime)
        value = evaluate(headers, runtime)
        llm_chat.with_headers(**value) if value && !value.empty?
      end

      def apply_schema(llm_chat, runtime)
        value = resolved_schema_value(runtime)
        llm_chat.with_schema(value) if value
      end

      def resolved_schema_value(runtime)
        value = schema
        return value unless value.is_a?(Proc)

        evaluate(value, runtime)
      rescue NoMethodError => e
        raise unless e.receiver.equal?(runtime)

        RubyLLM::Schema.create(&value)
      end

      def llm_chat_for(chat_object)
        apply_assume_model_exists(chat_object)
        chat_object.respond_to?(:to_llm) ? chat_object.to_llm : chat_object
      end

      def apply_assume_model_exists(chat_object)
        return unless chat_kwargs.key?(:assume_model_exists) &&
                      resolved_chat_model &&
                      chat_object.is_a?(resolved_chat_model)

        chat_object.assume_model_exists = chat_kwargs[:assume_model_exists]
      end

      def evaluate(value, runtime)
        value.is_a?(Proc) ? runtime.instance_exec(&value) : value
      end

      def resolved_instructions_value(chat_object, runtime, inputs:)
        value = evaluate(@instructions, runtime)
        return value unless prompt_instruction?(value)

        runtime.prompt(
          value[:prompt],
          **resolve_prompt_locals(value[:locals] || {}, runtime:, chat: chat_object, inputs:)
        )
      end

      def prompt_instruction?(value)
        value.is_a?(Hash) && value[:prompt]
      end

      def instruction_target(chat_object, persist:)
        if persist || !chat_object.respond_to?(:to_llm)
          chat_object
        else
          runtime_instruction_target(chat_object)
        end
      end

      def runtime_instruction_target(chat_object)
        return chat_object if chat_object.respond_to?(:with_runtime_instructions)

        chat_object.to_llm
      end

      def use_runtime_instructions?(target, persist:)
        !persist && target.respond_to?(:with_runtime_instructions)
      end

      def resolve_prompt_locals(locals, runtime:, chat:, inputs:)
        base = { chat: chat }.merge(inputs)
        evaluated = locals.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value.is_a?(Proc) ? runtime.instance_exec(&value) : value
        end
        base.merge(evaluated)
      end

      def partition_inputs(kwargs)
        input_values = {}
        chat_options = {}

        kwargs.each do |key, value|
          symbolized_key = key.to_sym
          if inputs.include?(symbolized_key)
            input_values[symbolized_key] = value
          else
            chat_options[symbolized_key] = value
          end
        end

        [input_values, chat_options]
      end

      # 构造"运行时上下文"对象 —— 一个匿名 Object，定义了：
      #   - `chat` 方法返回当前 chat
      #   - `prompt(:name)` 方法渲染 ERB
      #   - 每个 input 名都被定义为读取该 input 值的方法
      #
      # 该对象用作所有 Proc / block 的 `instance_exec` 接收者，
      # 让用户在 DSL 块中能写 `chat.messages` / `name` / `prompt(:foo)`
      # 等代码而无需显式参数。
      def runtime_context(chat:, inputs:)
        agent_class = self
        Object.new.tap do |runtime|
          runtime.define_singleton_method(:chat) { chat }
          runtime.define_singleton_method(:prompt) do |name, **locals|
            agent_class.render_prompt(name, chat:, inputs:, locals:)
          end

          inputs.each do |name, value|
            runtime.define_singleton_method(name) { value }
          end
        end
      end

      def prompt_path_for(name)
        filename = name.to_s
        filename += '.txt.erb' unless filename.end_with?('.txt.erb')
        prompt_root.join(prompt_agent_path, filename)
      end

      def prompt_agent_path
        class_name = name || 'agent'
        class_name.gsub('::', '/')
                  .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                  .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                  .tr('-', '_')
                  .downcase
      end

      def prompt_root
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join('app/prompts')
        else
          Pathname.new(Dir.pwd).join('app/prompts')
        end
      end

      def resolved_chat_model
        return @resolved_chat_model if defined?(@resolved_chat_model)

        @resolved_chat_model = case @chat_model
                               when String then Object.const_get(@chat_model)
                               else @chat_model
                               end
      end
    end

    # 实例化 Agent。
    #
    # @param chat [RubyLLM::Chat, nil] 已有的 Chat；为 nil 时按
    #   类级 `chat_kwargs` 新建
    # @param inputs [Hash, nil] 显式提供的 inputs（也可以混在 kwargs 中）
    # @param persist_instructions [Boolean] AR 持久化模式下是否把 system
    #   instructions 写回数据库
    # @param kwargs [Hash] 其余 kwargs 会被自动拆分为 inputs 和 Chat 选项
    def initialize(chat: nil, inputs: nil, persist_instructions: true, **kwargs)
      input_values, chat_options = self.class.send(:partition_inputs, kwargs)
      @chat = chat || RubyLLM.chat(**self.class.chat_kwargs, **chat_options)
      self.class.send(:apply_configuration, @chat, input_values: input_values.merge(inputs || {}),
                                                   persist_instructions:)
    end

    # 内部持有的 Chat 实例。
    # @return [RubyLLM::Chat]
    attr_reader :chat

    # 把常用 Chat 方法整体转发到 `@chat`，使 Agent 实例的调用方式与
    # Chat 几乎一致：`agent.ask`、`agent.with_tool(...)` 等。
    def_delegators :chat, :model, :messages, :tools, :params, :headers, :schema, :ask, :say, :with_tool, :with_tools,
                   :with_model, :with_temperature, :with_thinking, :with_context, :with_params, :with_headers,
                   :with_schema, :on_new_message, :on_end_message, :on_tool_call, :on_tool_result, :before_message,
                   :after_message, :before_tool_call, :after_tool_result, :each, :complete, :add_message,
                   :reset_messages!, :cost
  end
end
