# frozen_string_literal: true

require 'ruby_llm/schema'

module RubyLLM
  # Parameter definition for Tool methods.
  #
  # 工具参数的元数据描述（DSL `param :name, type: ..., desc: ..., required:` 用）。
  # 仅在用户没有提供完整 JSON Schema 或 RubyLLM::Schema 时被使用，
  # 由 {Tool::SchemaDefinition.from_parameters} 转成 JSON Schema。
  class Parameter
    # @return [Symbol] 参数名
    # @return [String] 类型字符串（'string'/'integer'/'array'/...）
    # @return [String, nil] 描述
    # @return [Boolean] 是否必填
    attr_reader :name, :type, :description, :required

    def initialize(name, type: 'string', desc: nil, description: nil, required: true)
      @name = name
      @type = type
      @description = desc || description
      @required = required
    end
  end

  # Base class for creating tools that AI models can use
  #
  # 工具基类 —— 让模型可以调用你写的 Ruby 方法。
  #
  # 用法：继承 `Tool`，实现 `execute(**args)` 方法，必要时通过 DSL
  # 描述参数：
  #
  #   class Weather < RubyLLM::Tool
  #     desc 'Get current weather'
  #     param :latitude, type: 'number'
  #     param :longitude, type: 'number'
  #
  #     def execute(latitude:, longitude:)
  #       ...
  #     end
  #   end
  #
  # 参数 schema 解析优先级（{#params_schema}）：
  # 1. `params {...}` 显式 DSL 提供的 JSON Schema 或 RubyLLM::Schema
  # 2. `param :name, ...` 累积的 {Parameter} 列表
  # 3. 从 `execute` 的 keyword 形参签名自动推断
  #
  # 工具名 {#name} 由类名转成 snake_case 并去掉 `_tool` 后缀，并清洗
  # 非 ASCII / 特殊字符（很多 provider 要求工具名只含 `[A-Za-z0-9_-]`）。
  class Tool
    # Stops conversation continuation after tool execution
    #
    # 工具返回值的特殊包装 —— 让 Chat 在执行完该工具后**立即停止**，
    # 不再触发后续的模型补全。常用于"提前终止"的场景，例如工具自身
    # 已能给出最终答复。
    class Halt
      # @return [Object] 真正要返回给上层的内容
      attr_reader :content

      def initialize(content)
        @content = content
      end

      def to_s
        @content.to_s
      end
    end

    # `execute` 形参中"按位置传递"的种类（用于判定工具实现是否
    # 接受位置参数 → 跳过严格的 keyword 校验）。
    POSITIONAL_PARAMETER_KINDS = %i[req opt rest].freeze

    class << self
      # @return [Tool::SchemaDefinition, nil] DSL `params {...}` 收集的定义
      attr_reader :params_schema_definition

      # 设置或读取工具描述（→ provider 中 tool.description 字段）。
      def description(text = nil)
        return @description unless text

        @description = text
      end
      alias desc description

      # 声明一个参数。
      #
      # @param name [Symbol]
      # @param options [Hash] 见 {Parameter#initialize}
      def param(name, **options)
        parameters[name] = Parameter.new(name, **options)
      end

      # 已声明参数的累积表（按声明顺序）。
      def parameters
        @parameters ||= {}
      end

      # 用显式 schema/block 声明参数。block 形态会被 `RubyLLM::Schema.create`
      # 包装。返回 self 便于链式。
      def params(schema = nil, &block)
        @params_schema_definition = SchemaDefinition.new(schema:, block:)
        self
      end

      # 注入 provider 专属的额外字段（如 OpenAI 的 `strict: true`）。
      def with_params(**params)
        @provider_params = params
        self
      end

      def provider_params
        @provider_params ||= {}
      end
    end

    # 工具名：把类名 normalize 成符合 provider 命名规则的 snake_case。
    # 步骤：unicode_normalize → 转 ASCII → 替换非法字符为 `-` →
    # CamelCase 拆分 → 全部小写 → 去掉 `_tool` 后缀。
    def name
      klass_name = self.class.name
      normalized = klass_name.to_s.dup.force_encoding('UTF-8').unicode_normalize(:nfkd)
      normalized.encode('ASCII', replace: '')
                .gsub(/[^a-zA-Z0-9_-]/, '-')
                .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                .downcase
                .delete_suffix('_tool')
    end

    # 透传到类级 description。
    def description = self.class.description
    # 透传到类级 parameters 累积表。
    def parameters = self.class.parameters
    # 透传到类级 provider_params。
    def provider_params = self.class.provider_params

    # 计算（并缓存）参数的 JSON Schema 表达。优先级见类级注释。
    def params_schema
      return @params_schema if defined?(@params_schema)

      @params_schema = begin
        definition = self.class.params_schema_definition
        if definition&.present?
          definition.json_schema
        elsif parameters.any?
          SchemaDefinition.from_parameters(parameters)&.json_schema
        else
          SchemaDefinition.from_parameters(inferred_parameters, allow_empty: true)&.json_schema
        end
      end
    end

    # 工具调用入口 —— 由 {Chat#execute_tool} 调用。
    #
    # 流程：normalize 参数（字符串 key → 符号）→ 校验 keyword 签名 →
    # 调用子类 `execute(**args)` → 记录 debug 日志 → 返回结果。
    # 校验失败时返回 `{error: "..."}`，模型可据此自行纠错。
    #
    # @param args [Hash, nil] 模型给出的参数 hash（字符串/符号 key 均可）
    # @return [Object]
    def call(args)
      normalized_args = normalize_args(args)
      validation_error = validate_keyword_arguments(normalized_args)
      return { error: "Invalid tool arguments: #{validation_error}" } if validation_error

      RubyLLM.logger.debug { "Tool #{name} called with: #{normalized_args.inspect}" }
      result = execute(**normalized_args)
      RubyLLM.logger.debug { "Tool #{name} returned: #{result.inspect}" }
      result
    end

    # 子类必须实现的执行方法。
    # @raise [NotImplementedError]
    def execute(...)
      raise NotImplementedError, 'Subclasses must implement #execute'
    end

    protected

    # 在 `execute` 内部使用：返回 `Halt(message)` 让 Chat 提前结束循环。
    def halt(message)
      Halt.new(message)
    end

    # 把字符串 key 统一为 symbol key（模型常返回字符串 key 的 JSON）。
    def normalize_args(args)
      return {} if args.nil?
      return args.transform_keys(&:to_sym) if args.respond_to?(:transform_keys)

      {}
    end

    # 校验模型给出的参数是否符合 `execute` 的 keyword 签名。
    #
    # 规则：
    # - `execute` 接受位置参数（**args / *rest 等）→ 跳过严格校验
    # - 必填 keyword 缺失 → 返回错误说明
    # - 出现未声明 keyword 且没有 **kwargs → 返回错误说明
    #
    # @return [String, nil] 错误描述；为 nil 表示通过
    def validate_keyword_arguments(arguments)
      required_keywords, optional_keywords, accepts_extra_keywords, accepts_positional_arguments =
        execute_keyword_signature

      return nil if required_keywords.empty? && optional_keywords.empty? && accepts_positional_arguments

      argument_keys = arguments.keys
      missing_keyword = first_missing_keyword(required_keywords, argument_keys)
      return "missing keyword: #{missing_keyword}" if missing_keyword
      return nil if accepts_extra_keywords

      allowed_keywords = required_keywords + optional_keywords
      unknown_keyword = first_unknown_keyword(argument_keys, allowed_keywords)
      return "unknown keyword: #{unknown_keyword}" if unknown_keyword

      nil
    end

    # 用 `Method#parameters` 反射 `execute` 的签名，分解为：
    # 必填 keyword 列表 / 可选 keyword 列表 / 是否含 **kwargs / 是否含位置参数。
    def execute_keyword_signature
      keyword_signature = method(:execute).parameters
      required_keywords = keyword_signature.filter_map { |kind, name| name if kind == :keyreq }
      optional_keywords = keyword_signature.filter_map { |kind, name| name if kind == :key }
      accepts_extra_keywords = keyword_signature.any? { |kind, _| kind == :keyrest }
      accepts_positional_arguments = keyword_signature.any? do |kind, _|
        POSITIONAL_PARAMETER_KINDS.include?(kind)
      end

      [required_keywords, optional_keywords, accepts_extra_keywords, accepts_positional_arguments]
    end

    def first_missing_keyword(required_keywords, argument_keys)
      (required_keywords - argument_keys).first
    end

    def first_unknown_keyword(argument_keys, allowed_keywords)
      (argument_keys - allowed_keywords).first
    end

    # 当用户没声明 param、也没用 `params {...}` 时，从 `execute` 形参
    # 反推一份 Parameter 列表（仅有名字 + required，没有 type/desc）。
    def inferred_parameters
      required_keywords, optional_keywords, = execute_keyword_signature

      (required_keywords + optional_keywords).to_h do |name|
        [name, Parameter.new(name, required: required_keywords.include?(name))]
      end
    end

    # Wraps schema handling for tool parameters, supporting JSON Schema hashes,
    # RubyLLM::Schema instances/classes, and DSL blocks.
    #
    # 工具参数 schema 的多形态适配器。
    #
    # 接受以下输入并统一产出 JSON Schema hash：
    # - Hash —— 直接当作 JSON Schema
    # - 响应 `to_json_schema` 的对象 —— 调用并提取 `.schema`
    # - Class（含 `to_json_schema` 实例方法）—— 实例化后调用
    # - block —— 用 `RubyLLM::Schema.create(&block)` 包装
    # - {Parameter} 列表（{from_parameters}）—— 自动构造 properties+required
    class SchemaDefinition
      # 从 {Parameter} 累积表构造 schema。
      #
      # @param parameters [Hash{Symbol => Parameter}]
      # @param allow_empty [Boolean] 是否允许空参数（用于"无参工具"）
      # @return [SchemaDefinition, nil]
      def self.from_parameters(parameters, allow_empty: false)
        return nil if parameters.nil? || (parameters.empty? && !allow_empty)

        properties = parameters.to_h do |name, param|
          schema = {
            type: map_type(param.type),
            description: param.description
          }.compact

          schema[:items] = default_items_schema if schema[:type] == 'array'

          [name.to_s, schema]
        end

        required = parameters.select { |_, param| param.required }.keys.map(&:to_s)

        json_schema = {
          type: 'object',
          properties: properties,
          required: required,
          additionalProperties: false,
          strict: true
        }

        new(schema: json_schema)
      end

      # 把 RubyLLM 简化类型名映射成 JSON Schema 标准类型名。
      def self.map_type(type)
        case type.to_s
        when 'integer', 'int' then 'integer'
        when 'number', 'float', 'double' then 'number'
        when 'boolean' then 'boolean'
        when 'array' then 'array'
        when 'object' then 'object'
        else
          'string'
        end
      end

      # array 类型的默认 items 形状（无 items 会被多家 provider 拒绝）。
      def self.default_items_schema
        { type: 'string' }
      end

      def initialize(schema: nil, block: nil)
        @schema = schema
        @block = block
      end

      # 是否实际持有 schema 内容。
      def present?
        @schema || @block
      end

      # 计算（并缓存）最终的 JSON Schema hash（key 全为字符串）。
      def json_schema
        @json_schema ||= RubyLLM::Utils.deep_stringify_keys(resolve_schema)
      end

      private

      # 解析入口：优先看显式 schema，再看 block。
      def resolve_schema
        return resolve_direct_schema(@schema) if @schema
        return build_from_block(&@block) if @block

        nil
      end

      # 处理多种"schema 对象"形态，统一抽出原生 hash。
      def resolve_direct_schema(schema)
        return extract_schema(schema.to_json_schema) if schema.respond_to?(:to_json_schema)
        return RubyLLM::Utils.deep_dup(schema) if schema.is_a?(Hash)
        if schema.is_a?(Class) && schema.method_defined?(:to_json_schema)
          return extract_schema(schema.new.to_json_schema)
        end

        nil
      end

      # 用 RubyLLM::Schema DSL 包装 block，再走 to_json_schema 通道。
      def build_from_block(&)
        schema_class = RubyLLM::Schema.create(&)
        extract_schema(schema_class.new.to_json_schema)
      end

      # 从 `{schema: {...}}` 的外层包装中拆出真正的 schema 定义。
      def extract_schema(schema_hash)
        return nil unless schema_hash.is_a?(Hash)

        schema = schema_hash[:schema] || schema_hash['schema'] || schema_hash
        RubyLLM::Utils.deep_dup(schema)
      end
    end
  end
end
