---
layout: default
title: Architecture
nav_order: 7
description: 项目结构与核心架构总览 —— 帮助贡献者理解 RubyLLM 的代码组织
---

# {{ page.title }}
{: .no_toc }

{{ page.description }}
{: .fs-6 .fw-300 }

## 目录
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## 一、项目概述

**RubyLLM** 是一个 Ruby gem，提供统一、优雅的 API 来对接各种 LLM 提供商（OpenAI、Anthropic、Gemini、Bedrock、xAI、Ollama 等）。

- **当前版本**：1.15
- **核心理念**：一套统一的 Ruby 接口屏蔽各家 AI 提供商的 API 差异
- **运行时依赖**：极少 —— 仅 `Faraday`、`Zeitwerk`、`Marcel`、`event_stream_parser`、`ruby_llm-schema`
- **支持 Ruby**：>= 3.1.3
- **作者**：Carmine Paolino，由 [chatwithwork.com](https://chatwithwork.com) 在生产环境中实战验证

## 二、顶层文件结构

```
ruby_llm/
├── lib/
│   ├── ruby_llm.rb              # 入口：Zeitwerk 加载 + Provider 注册
│   ├── ruby_llm/                # 核心代码
│   ├── generators/              # Rails 生成器 (install / chat_ui)
│   └── tasks/                   # Rake 任务 (models.rake / release.rake / vcr.rake)
├── spec/                        # RSpec 测试 + Rails dummy app + VCR fixtures
├── docs/                        # 站点文档（rubyllm.com）
├── gemfiles/ + Appraisals       # 多个 Faraday/Rails 版本矩阵测试
├── bin/                         # console / setup 等开发脚本
└── ruby_llm.gemspec             # gem 定义
```

## 三、核心架构（`lib/ruby_llm/`）

按职责可分为 **6 大层**。

### 1. 顶层 API（用户面向的 DSL）

| 文件 | 职责 |
|---|---|
| `ruby_llm.rb` | 模块入口；定义 `RubyLLM.chat / embed / paint / moderate / transcribe / models` 等便捷方法 |
| `chat.rb` | **核心类 `Chat`** — 多轮对话、工具调用、流式、回调、schema、thinking |
| `agent.rb` | **`Agent` 类** — 可继承的 agent 模板（DSL：`model`、`tools`、`instructions`、`schema`） |
| `embedding.rb` / `image.rb` / `moderation.rb` / `transcription.rb` | 单次任务封装 |
| `context.rb` / `configuration.rb` | 全局/局部配置（API keys、超时、重试、日志等） |

### 2. 消息 & 内容模型

`message.rb`、`content.rb`、`attachment.rb`、`chunk.rb`、`tool_call.rb`、`thinking.rb`、`tokens.rb`、`mime_type.rb`、`stream_accumulator.rb`

围绕一次会话的所有数据结构 —— 文本、图片、PDF、音频、工具调用、流块、token 记账、thinking 内容。

### 3. 提供商抽象层

- **`provider.rb`** — `Provider` 基类。统一 `complete / list_models / embed / moderate / paint / transcribe` 接口；模板方法模式（子类实现 `render_payload / parse_completion_response / completion_url` 等）。
- **`connection.rb`** — Faraday 连接封装（重试、日志中间件、超时）。
- **`streaming.rb`** — SSE 流处理（兼容 Faraday v1/v2）+ 错误事件解析。
- **`error.rb`** — 错误类型层级 + `ErrorMiddleware`。

### 4. 提供商实现（`providers/`）—— 13 家

每个提供商有：

- 顶层文件（如 `openai.rb`）：声明 `api_base`、`headers`、`configuration_requirements`
- 同名子目录：以 mixin 形式拆分能力 —— `chat.rb`、`streaming.rb`、`tools.rb`、`media.rb`、`embeddings.rb`、`images.rb`、`models.rb`、`transcription.rb`、`moderation.rb`、`capabilities.rb`

支持的 13 家提供商：`anthropic`、`azure`、`bedrock`、`deepseek`、`gemini`、`gpustack`、`mistral`、`ollama`、`openai`、`openrouter`、`perplexity`、`vertexai`、`xai`。

OpenAI 是最完整的实现（含图像、转录、审核、媒体），其他 OpenAI 兼容厂商往往复用其 mixin。

### 5. 模型注册表（`models.rb` + `model/` + `models.json`）

- `models.json`（**1.4 MB**）：内置 800+ 模型 + 其能力 + 定价
- `aliases.json` / `aliases.rb`：模型别名解析（`claude-sonnet-4` → 真实 ID）
- `model/info.rb` / `modalities.rb` / `pricing.rb` / `pricing_tier.rb` / `pricing_category.rb`：模型元数据 schema
- `cost.rb`：基于 token 计算费用（`response.cost.total`、`chat.cost.total` —— 1.15 新增）

### 6. Rails 集成

- `railtie.rb`：自动加载
- `active_record/`：核心是 `acts_as.rb`，提供 `acts_as_chat / acts_as_message / acts_as_model / acts_as_tool_call` —— 把 LLM 对话存到数据库；新旧两套并存（`acts_as_legacy.rb` + `acts_as.rb` + `chat_methods.rb` 等），通过 `config.use_new_acts_as` 切换
- `generators/`：`bin/rails generate ruby_llm:install` 生成迁移、模型；`ruby_llm:chat_ui` 生成完整的聊天 UI

## 四、关键架构模式

1. **模板方法 + Mixin 组合** — `Provider` 基类定义骨架，每家提供商通过 include `Chat / Streaming / Tools / ...` 等 mixin 注入具体行为。
2. **Zeitwerk 自动加载 + 显式 inflector** — `lib/ruby_llm.rb` 中给 `OpenAI / GPUStack / VertexAI / DeepSeek` 等做大小写矫正。
3. **链式构建器（fluent API）** — `Chat#with_model / with_tool / with_schema / with_thinking / with_temperature / with_params / with_headers`，每个返回 `self`。
4. **回调系统** — 新版 `before_message / after_message / before_tool_call / after_tool_result`（可叠加）+ 旧版 `on_*`（已废弃，会发警告）。
5. **配置项注册化** — `Configuration.option` 元编程；每个 provider 通过 `configuration_options` 把自己的配置项注册到全局 `Configuration` 类。
6. **Faraday 1/2 双兼容** — `streaming.rb` 内部分支（`req.options[:on_data]` vs `req.options.on_data`）。
7. **数据库覆盖 JSON 注册表** — 当应用 include `ActsAs` 时，`Models.load_models` 优先从数据库读模型清单（参见 `lib/ruby_llm/active_record/acts_as.rb:13-39`）。

## 五、测试与开发

- **RSpec** + **VCR**（`spec/fixtures/`）记录真实 API 响应做回放
- `spec/dummy/` 是一个 Rails 应用骨架，用于测试 `acts_as_*` 集成
- **Appraisal** 矩阵测试不同 Faraday / Rails 版本（`gemfiles/`）
- **Rake 任务**：
  - `models.rake` — 抓取并刷新 `models.json`
  - `vcr.rake` — 管理录制
  - `release.rake` — 发版
- `.rubocop.yml` + `.overcommit.yml` + `.gitleaks.toml` 等保证代码质量

## 六、整体数据流（一次 `chat.ask` 请求）

```
RubyLLM.chat
   └─> Chat#ask  →  build_content + add_message
                 →  Chat#complete
                       └─> Provider#complete
                             ├─ render_payload (provider mixin)
                             ├─ Connection.post (Faraday + retries + logging)
                             ├─ sync_response  → parse_completion_response
                             └─ stream_response → StreamAccumulator + SSE parsing
                       └─> 若有 tool_calls → execute_tool → 递归 complete
                       └─> 触发 callbacks (before/after_message, before/after_tool)
                       └─> 返回 Message（含 cost、tokens、thinking）
```

## 七、总结

这是一个**高度模块化、面向插件扩展**的 LLM 抽象层：

- 用 **Provider 基类 + mixin 组合**统一所有厂商
- 用**富 DSL（Chat / Agent）**面向用户
- 用 **ActiveRecord concerns** 实现 Rails 一键持久化
- 用**内置 800+ 模型注册表**处理价格、能力、别名
