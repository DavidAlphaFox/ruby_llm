# frozen_string_literal: true

module RubyLLM
  # 流式响应的单块增量（"chunk"）。
  #
  # 继承自 {Message} —— 一个 chunk 在结构上就是一条"小型 message"：
  # 可能携带一段文本片段、token 计数、单步 thinking 文本，或一个开启
  # 中的工具调用片段。{StreamAccumulator} 把多个 Chunk 累加成最终的
  # 完整 Message。
  #
  # provider 的 `Streaming` mixin 通过 `build_chunk(hash)` 把 SSE 解析
  # 出的 hash 实例化为本类。
  class Chunk < Message
  end
end
