# frozen_string_literal: true

module RubyLLM
  # Represents a conversation with an AI model
  #
  # 表示与 AI 模型的一次（多轮）会话。
  #
  # 这是 RubyLLM 面向用户的核心类。一个 `Chat` 实例承载：
  #
  # - **模型与 Provider**：通过 {#with_model} 解析得到的具体模型对象与
  #   对应的 Provider 实例。
  # - **消息历史**：`@messages` 数组，按时间顺序保存 `Message` 对象。
  # - **工具集**：`@tools` 哈希（`name => Tool 实例`），以及工具调用偏好
  #   `@tool_prefs`（`choice` 和 `calls`）。
  # - **请求级参数**：`@params`、`@headers` —— 透传给 provider 的额外
  #   字段；`@schema` —— 结构化输出 JSON Schema；`@thinking` —— 推理
  #   预算配置；`@temperature` —— 采样温度。
  # - **回调**：新版多回调 `@callbacks`（before/after_message,
  #   before_tool_call, after_tool_result），旧版单回调 `@on`（已废弃）。
  #
  # 大多数 `with_xxx` 方法返回 `self`，支持链式调用：
  #
  #   chat = RubyLLM.chat
  #     .with_model('claude-sonnet-4')
  #     .with_temperature(0.2)
  #     .with_tool(Weather)
  #     .with_schema(MySchema)
  #
  # 通过 include `Enumerable`（基于 {#each} 委托给 `messages`）支持
  # 遍历消息：`chat.each { |msg| ... }`、`chat.map(&:content)`。
  class Chat
    include Enumerable

    # @!attribute [r] model
    #   @return [RubyLLM::Model::Info] 当前使用的模型元数据
    # @!attribute [r] messages
    #   @return [Array<RubyLLM::Message>] 完整消息历史
    # @!attribute [r] tools
    #   @return [Hash{Symbol => RubyLLM::Tool}] 已注册工具
    # @!attribute [r] tool_prefs
    #   @return [Hash{Symbol => Object}] 工具调用偏好（`choice`/`calls`）
    # @!attribute [r] params
    #   @return [Hash] 透传给 provider 的额外请求字段
    # @!attribute [r] headers
    #   @return [Hash] 额外 HTTP 请求头
    # @!attribute [r] schema
    #   @return [Hash, nil] 结构化输出的 JSON Schema 描述
    attr_reader :model, :messages, :tools, :tool_prefs, :params, :headers, :schema

    # 初始化一次会话。
    #
    # @param model [String, nil] 模型 ID 或别名；为 nil 时使用
    #   `config.default_model`
    # @param provider [Symbol, String, nil] 显式指定 provider slug；
    #   通常可省略，由 Models 注册表自动推断
    # @param assume_model_exists [Boolean] 是否跳过模型注册表校验
    #   （用于使用注册表中尚未收录的新模型）；为 true 时必须同时指定
    #   `provider`，否则抛 ArgumentError
    # @param context [RubyLLM::Context, nil] 可选的局部上下文
    # @raise [ArgumentError] 当 `assume_model_exists=true` 但未提供
    #   `provider`
    def initialize(model: nil, provider: nil, assume_model_exists: false, context: nil)
      if assume_model_exists && !provider
        raise ArgumentError, 'Provider must be specified if assume_model_exists is true'
      end

      @context = context
      @config = context&.config || RubyLLM.config
      model_id = model || @config.default_model
      with_model(model_id, provider: provider, assume_exists: assume_model_exists)
      @temperature = nil
      @messages = []
      @tools = {}
      @tool_prefs = { choice: nil, calls: nil }
      @params = {}
      @headers = {}
      @schema = nil
      @thinking = nil
      @on = {
        new_message: nil,
        end_message: nil,
        tool_call: nil,
        tool_result: nil
      }
      @callbacks = Hash.new { |callbacks, name| callbacks[name] = [] }
    end

    # 向模型发起一次提问。
    #
    # 内部流程：把用户消息追加到历史，然后调用 {#complete} 触发补全。
    # 若提供了块，则进入流式模式，块会被逐 chunk 调用。
    #
    # @param message [String, RubyLLM::Content, nil] 用户消息文本，或
    #   已构造好的 `Content`
    # @param with [String, Array<String>, Hash, nil] 附件 —— 可以是
    #   单个文件路径、路径数组、或形如 `{image: '...', pdf: '...'}` 的哈希
    # @yield [chunk] 流式响应回调；每次收到 SSE chunk 时被调用
    # @yieldparam chunk [RubyLLM::Chunk] 流式增量
    # @return [RubyLLM::Message] 模型最终返回的 assistant 消息
    def ask(message = nil, with: nil, &)
      add_message role: :user, content: build_content(message, with)
      complete(&)
    end

    # `ask` 的别名，更口语化。
    alias say ask

    # 设置或追加 system 指令（system prompt）。
    #
    # @param instructions [String] 指令文本
    # @param append [Boolean] 为 true 时追加新的 system 消息；
    #   为 false（默认）时替换已有的 system 消息
    # @param replace [Boolean, nil] 旧版兼容参数；`replace: false` 等价
    #   于 `append: true`
    # @return [self]
    def with_instructions(instructions, append: false, replace: nil)
      append ||= (replace == false) unless replace.nil?

      if append
        append_system_instruction(instructions)
      else
        replace_system_instruction(instructions)
      end

      self
    end

    # 注册单个工具。
    #
    # @param tool [Class<RubyLLM::Tool>, RubyLLM::Tool, nil] 工具类或实例
    # @param choice [Symbol, String, Class, nil] 工具调用偏好；可选值：
    #   `:auto` / `:none` / `:required` / 工具名 / 工具类
    # @param calls [Symbol, Integer, nil] `:many`（默认，可多次调用）
    #   或 `:one`/`1`（仅一次）
    # @return [self]
    def with_tool(tool, choice: nil, calls: nil)
      unless tool.nil?
        tool_instance = tool.is_a?(Class) ? tool.new : tool
        @tools[tool_instance.name.to_sym] = tool_instance
      end
      update_tool_options(choice:, calls:)
      self
    end

    # 批量注册工具。
    #
    # @param tools [Array<Class, RubyLLM::Tool>] 工具类/实例列表
    # @param replace [Boolean] 是否先清空已注册的工具
    # @param choice [Symbol, String, Class, nil] 见 {#with_tool}
    # @param calls [Symbol, Integer, nil] 见 {#with_tool}
    # @return [self]
    def with_tools(*tools, replace: false, choice: nil, calls: nil)
      @tools.clear if replace
      tools.compact.each { |tool| with_tool tool }
      update_tool_options(choice:, calls:)
      self
    end

    # 切换模型。会通过 Models 注册表解析得到具体模型对象与 Provider，
    # 并刷新底层 Faraday 连接。
    #
    # @param model_id [String] 模型 ID 或别名
    # @param provider [Symbol, String, nil] 强制指定 provider
    # @param assume_exists [Boolean] 是否跳过注册表校验
    # @return [self]
    def with_model(model_id, provider: nil, assume_exists: false)
      @model, @provider = Models.resolve(model_id, provider:, assume_exists:, config: @config)
      @connection = @provider.connection
      self
    end

    # 设置采样温度。
    #
    # @param temperature [Float] 范围一般为 `0.0` ~ `2.0`，具体取决于
    #   provider；OpenAI o-系列模型可能强制为 1.0
    # @return [self]
    def with_temperature(temperature)
      @temperature = temperature
      self
    end

    # 启用扩展思考（extended thinking / reasoning），并指定预算。
    #
    # `effort` 与 `budget` 必须至少提供一个，否则抛 ArgumentError。
    #
    # @param effort [Symbol, nil] 思考强度，例如 `:low/:medium/:high`
    #   （由 provider 解释；OpenAI/Anthropic 用法不同）
    # @param budget [Integer, nil] 思考 token 预算上限
    # @raise [ArgumentError]
    # @return [self]
    def with_thinking(effort: nil, budget: nil)
      raise ArgumentError, 'with_thinking requires :effort or :budget' if effort.nil? && budget.nil?

      @thinking = Thinking::Config.new(effort: effort, budget: budget)
      self
    end

    # 切换上下文。会以 `assume_exists: true` 的方式重新解析当前模型，
    # 因为新上下文可能携带不同的注册表/凭据。
    #
    # @param context [RubyLLM::Context]
    # @return [self]
    def with_context(context)
      @context = context
      @config = context.config
      with_model(@model.id, provider: @provider.slug, assume_exists: true)
      self
    end

    # 设置透传给 provider 的额外请求体字段（如 `top_p`、`seed`、
    # provider 特有字段等）。会**整体覆盖**之前设置的 params。
    #
    # @param params [Hash]
    # @return [self]
    def with_params(**params)
      @params = params
      self
    end

    # 设置透传给 provider 的额外 HTTP 请求头。
    #
    # @param headers [Hash{String => String}]
    # @return [self]
    def with_headers(**headers)
      @headers = headers
      self
    end

    # 启用结构化输出（JSON Schema）。
    #
    # 接受多种形态：`RubyLLM::Schema` 子类、其实例、原生 Hash、或任何
    # 响应 `to_json_schema` 的对象。内部会规范化成 provider 期望的载荷。
    #
    # @param schema [Class, Object, Hash]
    # @return [self]
    def with_schema(schema)
      schema_instance = schema.is_a?(Class) ? schema.new : schema

      @schema = normalize_schema_payload(
        schema_instance.respond_to?(:to_json_schema) ? schema_instance.to_json_schema : schema_instance
      )

      self
    end

    # @!group 旧版（v1.x）单回调接口 —— 已废弃，将于 2.0 移除
    # 这些 `on_*` 方法每个事件只能注册一个回调；建议改用同语义的
    # `before_message` / `after_message` / `before_tool_call` /
    # `after_tool_result`（多回调可叠加）。

    # @deprecated 使用 {#before_message}
    def on_new_message(&)
      set_legacy_callback(:new_message, :on_new_message, :before_message, &)
    end

    # @deprecated 使用 {#after_message}
    def on_end_message(&)
      set_legacy_callback(:end_message, :on_end_message, :after_message, &)
    end

    # @deprecated 使用 {#before_tool_call}
    def on_tool_call(&)
      set_legacy_callback(:tool_call, :on_tool_call, :before_tool_call, &)
    end

    # @deprecated 使用 {#after_tool_result}
    def on_tool_result(&)
      set_legacy_callback(:tool_result, :on_tool_result, :after_tool_result, &)
    end
    # @!endgroup

    # @!group 新版多回调接口（可叠加注册）

    # 在每条新消息**写入历史之前**触发。
    #
    # @yield 无参回调
    # @return [self]
    def before_message(&)
      add_callback(:before_message, &)
    end

    # 在每条消息（含工具调用结果）写入历史**之后**触发。
    #
    # @yieldparam message [RubyLLM::Message] 刚写入的消息
    # @return [self]
    def after_message(&)
      add_callback(:after_message, &)
    end

    # 在执行工具**之前**触发。
    #
    # @yieldparam tool_call [RubyLLM::ToolCall]
    # @return [self]
    def before_tool_call(&)
      add_callback(:before_tool_call, &)
    end

    # 在工具执行**结果就绪后**触发。
    #
    # @yieldparam result [Object] 工具返回值（或 `Tool::Halt` 包装）
    # @return [self]
    def after_tool_result(&)
      add_callback(:after_tool_result, &)
    end
    # @!endgroup

    # `Enumerable` 的实现 —— 委托给 `messages` 数组。
    #
    # @yield [message]
    # @return [Enumerator] 当未给块时
    def each(&)
      messages.each(&)
    end

    # 整个会话的累计费用。
    #
    # @return [RubyLLM::Cost] 聚合后的费用对象（含 input/output/total 等）
    def cost
      Cost.aggregate(messages.map(&:cost))
    end

    # 触发一次补全请求。
    #
    # 这是 `ask` 的下层方法。内部职责：
    #   1. 调用 `provider.complete(...)`，根据是否传入块决定同步/流式
    #   2. 若启用 schema 且模型返回的是 JSON 字符串，尝试解析为 Hash
    #   3. 把响应消息追加到历史
    #   4. 触发 before/after_message 回调
    #   5. 若响应含工具调用，进入 {#handle_tool_calls} 递归补全
    #
    # @yield [chunk] 流式 chunk 回调（可选）
    # @return [RubyLLM::Message] assistant 消息（工具循环结束后的最终结果）
    def complete(&)
      response = @provider.complete(
        messages,
        tools: @tools,
        tool_prefs: @tool_prefs,
        temperature: @temperature,
        model: @model,
        params: @params,
        headers: @headers,
        schema: @schema,
        thinking: @thinking,
        &wrap_streaming_block(&)
      )

      run_callbacks(:before_message, :new_message) unless block_given?

      if @schema && response.content.is_a?(String) && !response.tool_call?
        begin
          response.content = JSON.parse(response.content)
        rescue JSON::ParserError
          # If parsing fails, keep content as string
          # 解析失败时降级为原字符串，调用方自行处理。
        end
      end

      add_message response
      run_callbacks(:after_message, :end_message, response)

      if response.tool_call?
        handle_tool_calls(response, &)
      else
        response
      end
    end

    # 向历史追加一条消息。可接受 `Message` 实例，或可传给
    # `Message.new` 的属性 Hash。
    #
    # @param message_or_attributes [RubyLLM::Message, Hash]
    # @return [RubyLLM::Message] 追加后的消息
    def add_message(message_or_attributes)
      message = message_or_attributes.is_a?(Message) ? message_or_attributes : Message.new(message_or_attributes)
      messages << message
      message
    end

    # 清空消息历史（用于"开始新一轮对话"，但保留模型/工具/参数等配置）。
    #
    # @return [Array<RubyLLM::Message>] 清空后的（空）历史数组
    def reset_messages!
      @messages.clear
    end

    # 覆盖默认 `instance_variables`：在 `inspect` / pp 时**隐藏** Faraday
    # 连接和配置对象，避免输出时打印大量内部细节。
    #
    # @return [Array<Symbol>]
    def instance_variables
      super - %i[@connection @config]
    end

    private

    # 把用户提供的多种 schema 形态规范化为 provider 期望的载荷。
    #
    # 输出形如：`{ name:, schema: {...}, strict: true, description: ... }`
    #
    # @param raw_schema [Hash, nil]
    # @return [Hash, nil]
    def normalize_schema_payload(raw_schema)
      return nil if raw_schema.nil?
      return raw_schema unless raw_schema.is_a?(Hash)

      schema = RubyLLM::Utils.deep_symbolize_keys(raw_schema)
      schema_def = extract_schema_definition(schema)
      strict = extract_schema_strict(schema, schema_def)
      build_schema_payload(schema, schema_def, strict)
    end

    # 从外层 hash 中抽出真正的 JSON Schema 定义（容忍 `{schema: {...}}`
    # 这种嵌套形式）。
    #
    # @return [Hash]
    def extract_schema_definition(schema)
      RubyLLM::Utils.deep_dup(schema[:schema] || schema)
    end

    # 决定 strict 模式：优先外层显式 `:strict`，其次 schema 内嵌的，
    # 否则为 nil（在 {#build_schema_payload} 中默认 true）。
    def extract_schema_strict(schema, schema_def)
      return schema[:strict] if schema.key?(:strict)
      return schema_def.delete(:strict) if schema_def.is_a?(Hash)

      nil
    end

    # 拼装最终的 schema 载荷；nil 字段会通过 `compact` 删除。
    def build_schema_payload(schema, schema_def, strict)
      {
        name: sanitize_schema_name(schema[:name] || 'response'),
        schema: schema_def,
        strict: strict.nil? || strict,
        description: schema[:description]
      }.compact
    end

    # 清洗 schema 名称：仅保留字母数字下划线连字符，避免 provider 拒绝。
    #
    # @param name [#to_s]
    # @return [String]
    def sanitize_schema_name(name)
      sanitized = name.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')
      sanitized.empty? ? 'response' : sanitized
    end

    # 向多回调表追加一个回调。
    #
    # @return [self]
    def add_callback(name, &block)
      @callbacks[name] << block if block
      self
    end

    # 设置旧版单回调，并打印 deprecation 警告。
    def set_legacy_callback(name, legacy_name, additive_name, &block)
      warn_legacy_callback_deprecation(legacy_name, additive_name) if block

      @on[name] = block
      self
    end

    def warn_legacy_callback_deprecation(legacy_name, additive_name)
      RubyLLM.logger.warn(
        "`#{legacy_name}` is deprecated and will be removed in RubyLLM 2.0. " \
        "Use `#{additive_name}` instead."
      )
    end

    # 触发某事件的所有新版多回调，再触发同义的旧版单回调。
    #
    # @param name [Symbol] 新版回调名（如 `:before_message`）
    # @param legacy_name [Symbol] 旧版同义回调名（如 `:new_message`）
    # @param args [Array] 透传给回调的参数
    def run_callbacks(name, legacy_name, *args)
      @callbacks[name].each { |callback| callback.call(*args) }
      @on[legacy_name]&.call(*args)
    end

    # 包装用户的流式块：在第一个 chunk 到达前先触发 before_message
    # 回调，然后逐 chunk 透传给用户块。
    #
    # @return [Proc, nil]
    def wrap_streaming_block(&block)
      return nil unless block_given?

      run_callbacks(:before_message, :new_message)

      proc do |chunk|
        block.call chunk
      end
    end

    # 处理一次 assistant 响应中携带的工具调用。
    #
    # 行为：
    #   - 遍历每个 tool_call，触发 before_tool_call 回调，调用工具
    #   - 触发 after_tool_result 回调，把结果作为 role=:tool 消息写回历史
    #   - 若任一工具返回 `Tool::Halt`，立即返回它而不再递归补全
    #   - 若 tool_choice 是强制的（非 auto/none），重置为 nil 防死循环
    #   - 否则递归调用 {#complete} 让模型基于工具结果继续生成
    #
    # @param response [RubyLLM::Message] 触发本轮工具调用的 assistant 消息
    # @yield [chunk] 透传的流式块
    # @return [RubyLLM::Message, Tool::Halt]
    def handle_tool_calls(response, &)
      halt_result = nil

      response.tool_calls.each_value do |tool_call|
        run_callbacks(:before_message, :new_message)
        run_callbacks(:before_tool_call, :tool_call, tool_call)
        result = execute_tool tool_call
        run_callbacks(:after_tool_result, :tool_result, result)
        tool_payload = result.is_a?(Tool::Halt) ? result.content : result
        content = content_like?(tool_payload) ? tool_payload : tool_payload.to_s
        message = add_message role: :tool, content:, tool_call_id: tool_call.id
        run_callbacks(:after_message, :end_message, message)

        halt_result = result if result.is_a?(Tool::Halt)
      end

      reset_tool_choice if forced_tool_choice?
      halt_result || complete(&)
    end

    # 实际执行一次工具调用。若模型试图调用未注册的工具，返回带错误描述
    # 的 Hash，模型可据此自行纠错。
    #
    # @param tool_call [RubyLLM::ToolCall]
    # @return [Object]
    def execute_tool(tool_call)
      tool = tools[tool_call.name.to_sym]
      if tool.nil?
        return {
          error: "Model tried to call unavailable tool `#{tool_call.name}`. " \
                 "Available tools: #{tools.keys.to_json}."
        }
      end

      args = tool_call.arguments
      tool.call(args)
    end

    # 校验并写入工具偏好。
    # `choice` 必须是 `:auto/:none/:required` 或已注册的工具名，
    # `calls` 必须是 `:many/:one/1`。
    #
    # @raise [InvalidToolChoiceError, ArgumentError]
    def update_tool_options(choice:, calls:)
      unless choice.nil?
        normalized_choice = normalize_tool_choice(choice)
        valid_tool_choices = %i[auto none required] + tools.keys
        unless valid_tool_choices.include?(normalized_choice)
          raise InvalidToolChoiceError,
                "Invalid tool choice: #{choice}. Valid choices are: #{valid_tool_choices.join(', ')}"
        end

        @tool_prefs[:choice] = normalized_choice
      end

      @tool_prefs[:calls] = normalize_calls(calls) unless calls.nil?
    end

    def normalize_calls(calls)
      case calls
      when :many, 'many'
        :many
      when :one, 'one', 1
        :one
      else
        raise ArgumentError, "Invalid calls value: #{calls.inspect}. Valid values are: :many, :one, or 1"
      end
    end

    # 把 choice 参数（字符串/符号/类/实例）规范化为 Symbol。
    def normalize_tool_choice(choice)
      return choice.to_sym if choice.is_a?(String) || choice.is_a?(Symbol)
      return tool_name_for_choice_class(choice) if choice.is_a?(Class)

      choice.respond_to?(:name) ? choice.name.to_sym : choice.to_sym
    end

    # 给定一个工具类，找到它在已注册工具中对应的名字；若无匹配则按
    # snake_case 推断（如 `WeatherTool` → `:weather_tool`）。
    def tool_name_for_choice_class(tool_class)
      matched_tool_name = tools.find { |_name, tool| tool.is_a?(tool_class) }&.first
      return matched_tool_name if matched_tool_name

      classify_tool_name(tool_class.name)
    end

    # 类名 → snake_case 符号。
    def classify_tool_name(class_name)
      class_name.split('::').last
                .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                .downcase
                .to_sym
    end

    # 当前是否处于"强制工具调用"状态（即 choice 既非 auto 也非 none）。
    def forced_tool_choice?
      @tool_prefs[:choice] && !%i[auto none].include?(@tool_prefs[:choice])
    end

    # 重置工具选择 —— 完成一轮强制工具调用后清除偏好，避免无限循环。
    def reset_tool_choice
      @tool_prefs[:choice] = nil
    end

    # 把用户传入的 message+attachments 组装成 `Content` 对象。
    # 若已经是 Content / Content::Raw 则直接返回。
    def build_content(message, attachments)
      return message if content_like?(message)

      Content.new(message, attachments)
    end

    def content_like?(object)
      object.is_a?(Content) || object.is_a?(Content::Raw)
    end

    # 在已有 system 消息的基础上**追加**一条新的 system 消息，并把所有
    # system 消息保持在历史前部。
    def append_system_instruction(instructions)
      system_messages, non_system_messages = @messages.partition { |msg| msg.role == :system }
      system_messages << Message.new(role: :system, content: instructions)
      @messages = system_messages + non_system_messages
    end

    # **替换**唯一的 system 消息内容（若不存在则插入一条）。
    # 仅保留首条 system 消息，多余的会被丢弃。
    def replace_system_instruction(instructions)
      system_messages, non_system_messages = @messages.partition { |msg| msg.role == :system }

      if system_messages.empty?
        system_messages = [Message.new(role: :system, content: instructions)]
      else
        system_messages.first.content = instructions
        system_messages = [system_messages.first]
      end

      @messages = system_messages + non_system_messages
    end
  end
end
