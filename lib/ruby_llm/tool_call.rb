# frozen_string_literal: true

module RubyLLM
  # Represents a function call from an AI model to a Tool.
  #
  # 一次工具调用 —— 模型发出的"请帮我执行某函数"请求。
  #
  # 一条 assistant {Message} 的 `tool_calls` 是 `{id => ToolCall}` 哈希；
  # {Chat#handle_tool_calls} 会遍历执行，把结果以 role=:tool 的消息
  # 写回历史，然后递归 {Chat#complete}。
  #
  # `thought_signature` 是 Anthropic 的"加密推理签名"（用于在多轮工具
  # 调用之间保持思考链一致性）；其他 provider 可为 nil。
  #
  # 流式过程中 arguments 暂时是字符串（JSON 片段累加），结束后由
  # {StreamAccumulator#tool_calls_from_stream} 解析为 Hash。
  class ToolCall
    # @return [String] provider 给出的调用 id
    # @return [String] 工具名（用于在 Chat#tools 中查找）
    # @return [Hash, String] 参数；流式累加期间是字符串
    attr_reader :id, :name, :arguments
    # @return [String, nil] Anthropic 加密推理签名
    attr_accessor :thought_signature

    # @param id [String]
    # @param name [String]
    # @param arguments [Hash, String]
    # @param thought_signature [String, nil]
    def initialize(id:, name:, arguments: {}, thought_signature: nil)
      @id = id
      @name = name
      @arguments = arguments
      @thought_signature = thought_signature
    end

    # 序列化为 hash（持久化用）。
    def to_h
      {
        id: @id,
        name: @name,
        arguments: @arguments,
        thought_signature: @thought_signature
      }.compact
    end
  end
end
