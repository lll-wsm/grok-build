# 修复方案: 文本模型图片输入报错 (GLM / DeepSeek)

**日期:** 2026-08-06
**分支:** `custom-main`
**状态:** 已实施 - 待审查

---

## 1. 问题描述

配置文本模型(如 GLM-5.2)作为主模型时,任何包含图片的请求都会报错:

```
Retry failed: API error (status 400 Bad Request): BadRequest: Model only support text input
```

触发场景:
- `read_file` 读取图片文件 (PNG/JPG) 或 PDF (渲染为图片)
- 用户在终端粘贴图片
- 对话历史中残留的图片内容

一旦图片进入对话,**后续每轮请求都会失败**,因为完整历史(含图片)会被重新发送。

---

## 2. 根因分析

### 2.1 已有 Image Describe 机制但被禁用

系统**已经实现了**"用视觉模型描述图片,把文本描述给主模型"的完整流程:

- `image_describe.rs` - 构建描述 prompt、调用视觉模型、渲染描述结果
- `transcribe_user_images()` (`prompt_build.rs:820`) - 编排整个描述流程
- `ImageDescribeCache` - 缓存描述结果,避免重复调用

描述流程的工作方式:
```
用户图片 -> 调用 image_description_model (视觉模型) -> 生成文字描述
  -> 包装为 <image><image_description>...</image_description></image>
  -> 作为文本注入用户消息 -> 主模型收到的是文字描述,不是图片
```

**但这个流程被禁用了。** 在 `turn.rs:710` 中:

```rust
let user_message = if user_images.is_empty() {
    user_message
} else if self.is_cursor_harness() {        // ← 只有 cursor harness 才走 describe
    self.transcribe_user_images(...)         // ← 用视觉模型描述图片
} else {
    persist_and_prepend_image_files(...)     // ← grok-build harness: 图片直接 inline 发给主模型
};
```

而 `is_cursor_harness()` 在当前构建中**硬编码返回 `false`** (`session_mode.rs:39`):

```rust
pub(super) fn is_cursor_harness(&self) -> bool {
    false  // ← describe 流程永远不会触发
}
```

结果:所有图片(用户粘贴、read_file)都以 inline `ContentPart::Image` 方式直接发给主模型,不管主模型是否支持图片。

### 2.2 没有模型能力标志

`ModelEntryConfig` (`agent/config.rs:3823`) 有 `supports_reasoning_effort`、`supports_backend_search` 等能力标志,但**没有 `supports_image_input`**。系统默认所有模型都支持多模态输入。

### 2.3 错误匹配太窄,无法自动恢复

`is_image_processing_error()` (`error.rs:322`) 只匹配一种错误消息:

```rust
if matches!(status.as_u16(), 400 | 500)
    && message.contains("Could not process image")  // ← 只匹配 xAI Grok 格式
```

GLM 返回 `"Model only support text input"`,不匹配。错误未被识别为图片相关,`RetryWithImageStrip` 不触发。400 也不在可重试状态码列表中,最终判定为 Fatal 直接报错。

### 2.4 完整的失败链路

```
图片进入请求 -> GLM 返回 400 "Model only support text input"
  -> is_image_processing_error() 不匹配  ← 恢复失效
  -> 400 不可重试 -> Fatal -> 用户看到报错
```

---

## 3. 修复策略: 三层方案

| 层级 | 机制 | 效果 |
|------|------|------|
| **Layer 1: Image Describe 转发** | 启用已有的 `transcribe_user_images` 流程 | 图片 -> 视觉模型描述 -> **文本描述给主模型**(模型能理解图片内容) |
| **Layer 2: 模型能力标志** | 添加 `supports_image_input` 字段 | `read_file` 等工具感知模型能力,避免不必要地返回图片 |
| **Layer 3: 错误恢复扩展** | 扩展 `is_image_processing_error()` 匹配 | 兜底:万一图片漏到请求中,自动剥离并重试 |

Layer 1 是核心改进 - 模型获得有意义的图片描述,而不是丢弃图片。Layer 3 是安全网。

---

## 4. Layer 1: 启用 Image Describe 转发

### 4.1 核心思路

当主模型不支持图片时,让用户粘贴的图片走 `transcribe_user_images` 流程,而不是直接 inline 发送:

```
用户粘贴图片
  -> image_description_model (如 Grok-4.5) 描述图片
  -> 生成文字描述
  -> 包装为 <image><image_description>...</image_description></image>
  -> 作为文本注入用户消息
  -> GLM 主模型收到文字描述,正常处理
```

### 4.2 修改调用条件

**文件:** `crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn.rs:710`

**现状:**
```rust
} else if self.is_cursor_harness() {
    self.transcribe_user_images(user_message, &user_images).await?
} else {
    persist_and_prepend_image_files(...)
}
```

**改为:**
```rust
} else if self.is_cursor_harness() || !self.supports_image_input().await {
    self.transcribe_user_images(user_message, &user_images).await?
} else {
    persist_and_prepend_image_files(...)
}
```

### 4.3 添加 `supports_image_input()` 方法

**文件:** `crates/codegen/xai-grok-shell/src/session/acp_session_impl/session_mode.rs`

```rust
/// Whether the current session model supports image (multimodal) input.
/// When false, user images are routed through the image-description
/// pipeline instead of being sent inline.
pub(super) async fn supports_image_input(&self) -> bool {
    let config = self.reconstruct_full_config().await;
    // 从 ModelEntryConfig 读取 supports_image_input 字段
    // 默认 true (Grok 支持图片)
    self.model_catalog()
        .get(&config.model)
        .map(|m| m.supports_image_input)
        .unwrap_or(true)
}
```

### 4.4 read_file 图片处理

**文件:** `crates/codegen/xai-grok-shell/src/session/acp_session_impl/tool_calls.rs:2420`

当 `read_file` 返回 `ReadFileOutput::ImageContent` 时,当前逻辑直接将图片 inline 附加到消息:

```rust
if !self.is_cursor_harness()
    && let ToolsToolOutput::ReadFile(ReadFileOutput::ImageContent(ref image_content)) = result.output
{
    // 直接 inline 发送图片...
}
```

两种处理方式:

| 方式 | 行为 | 优点 | 缺点 |
|------|------|------|------|
| **A: 走 describe 流程** | 用 `image_description_model` 描述 read_file 读到的图片 | 模型获得图片文字描述 | 需要额外 API 调用,改动较大 |
| **B: 返回文本说明** | 返回 `"图片文件 xxx.png (2.3MB),当前模型不支持图片输入"` | 改动小,无额外 API 调用 | 模型看不到图片内容 |

**推荐方式 B** 作为初始实现(简单、安全),方式 A 可作为后续增强。

### 4.5 用户配置

用户需要配置一个支持图片的 `image_description_model`:

```toml
[model.glm-5-2]
model = "GLM-5.2"
base_url = "https://ark.cn-beijing.volces.com/api/coding/v3"
api_backend = "chat_completions"
env_key = "SZ_ARK_API_KEY"
context_window = 512000
supports_image_input = false        # ← 新增:标记 GLM 不支持图片

[model.grok-4.5]
model = "grok-4.5"
# ... (支持图片的模型,用于描述图片)

[models]
default = "glm-5-2"
image_description = "grok-4.5"      # ← 改为支持图片的模型
```

---

## 5. Layer 2: 模型能力标志

### 5.1 添加配置字段

**文件:** `crates/codegen/xai-grok-shell/src/agent/config.rs` - `ModelEntryConfig` 结构体 (约 L3925, `supports_backend_search` 之后)

```rust
/// Whether this model supports image (multimodal) input.
/// When false, user images are routed through the image-description
/// pipeline (image_description_model) instead of being sent inline.
/// Defaults to true (Grok models support images).
/// Set to false for text-only models (GLM, DeepSeek, etc.).
#[serde(default = "default_true")]
pub supports_image_input: bool,
```

### 5.2 影响范围

| 组件 | 行为变化 |
|------|---------|
| 用户粘贴图片 (`turn.rs`) | `supports_image_input=false` -> 走 `transcribe_user_images` describe 流程 |
| `read_file` 读取图片 (`tool_calls.rs`) | `supports_image_input=false` -> 返回文本说明,不 inline 附加 |
| 用户粘贴图片提示 (`paste.rs`, 可选) | `supports_image_input=false` -> 显示"当前模型不支持图片,将通过描述模型处理" |

---

## 6. Layer 3: 错误恢复扩展 (兜底)

### 6.1 扩展错误匹配

**文件:** `crates/codegen/xai-grok-sampling-types/src/error.rs:322`

```rust
// 现状
&& message.contains("Could not process image")

// 改为
&& (message.contains("Could not process image")
    || message.contains("only support text"))
```

`"only support text"` 是 GLM 错误 `"Model only support text input"` 的稳定子串,大小写一致,误匹配风险低。

### 6.2 修复占位符文本

**文件:** `crates/codegen/xai-grok-sampling-types/src/conversation.rs:644`

```rust
// 现状 (为 413 场景写的,语义不准确)
"[image removed - conversation too large]"

// 改为 (通用,适用于所有剥离场景)
"[image content removed]"
```

### 6.3 兜底恢复流程

```
图片漏入请求 -> GLM 返回 400 "Model only support text input"
  -> is_image_processing_error() 匹配 "only support text" ✓
  -> classify_error() 返回 RetryWithImageStrip
  -> strip_images() 替换为 "[image content removed]"
  -> 重试 (纯文本) -> GLM 正常响应 ✓
```

---

## 7. 文件改动清单

### Layer 1: Image Describe 转发

| 文件 | 改动 |
|------|------|
| `xai-grok-shell/src/agent/config.rs` (~L3925) | 添加 `supports_image_input: bool` 字段到 `ModelEntryConfig` |
| `xai-grok-shell/src/session/acp_session_impl/session_mode.rs` | 添加 `supports_image_input()` 方法 |
| `xai-grok-shell/src/session/acp_session_impl/turn.rs:710` | 条件增加 `\|\| !self.supports_image_input()` |
| `xai-grok-shell/src/session/acp_session_impl/tool_calls.rs:2420` | `read_file` 图片:不支持时返回文本说明 |

### Layer 3: 错误恢复扩展

| 文件 | 改动 |
|------|------|
| `xai-grok-sampling-types/src/error.rs:322` | 添加 `\|\| message.contains("only support text")` |
| `xai-grok-sampling-types/src/conversation.rs:644` | 占位符改为 `"[image content removed]"` |

---

## 8. 测试计划

### Layer 1 测试

| 测试名 | 验证 |
|--------|------|
| `user_image_routed_to_describe_when_unsupported` | `supports_image_input=false` -> 用户图片走 `transcribe_user_images` |
| `user_image_sent_inline_when_supported` | `supports_image_input=true` (默认) -> 图片 inline 发送 |
| `read_file_image_returns_text_when_unsupported` | `supports_image_input=false` -> `read_file` 读 PNG 返回文本说明 |
| `read_file_image_returns_image_when_supported` | `supports_image_input=true` -> `read_file` 读 PNG 返回 `ImageContent` |

### Layer 3 测试

| 测试名 | 输入 | 期望 |
|--------|------|------|
| `image_processing_error_text_only_model_400_detected` | 400 + `"Model only support text input"` | `is_image_processing_error() == true` |
| `image_processing_error_text_only_model_500_wrapped` | 500 + `"upstream: 400: Model only support text input"` | `is_image_processing_error() == true` |
| `image_processing_error_unrelated_400_not_detected` (现有) | 400 + `"Invalid model parameter"` | `is_image_processing_error() == false` |
| `test_strip_images_removes_user_images` (现有) | - | 占位符文本改为 `"[image content removed]"` |

---

## 9. 边界情况

| 场景 | 行为 | 正确? |
|------|------|-------|
| 主模型支持图片 | 图片 inline 发送,正常流程 | ✓ |
| 主模型不支持图片,用户粘贴图片 | Layer 1: describe 流程 -> 文本描述给主模型 | ✓ |
| 主模型不支持图片,read_file 读图片 | Layer 1: 返回文本说明(方式 B) | ✓ |
| 主模型不支持图片,describe 模型也不支持 | describe 调用失败 -> 报错(需要配置正确的 image_description_model) | ⚠ |
| 图片漏入请求(未知路径) | Layer 3: 剥离 -> 重试 -> 成功 | ✓ |
| 请求无图片但返回 "only support text" | `strip_images()` 返回 0 -> Fatal | ✓ (真正的非图片错误) |
| 对话历史有多张图片 | `strip_images()` 一次性剥离所有 | ✓ |
| 重试预算 (`max_retries=8`) | 图片剥离消耗 1 次重试 | ✓ |
| `image_description_model` 未配置 | fallback 到主模型 (GLM) -> describe 失败 | ⚠ 需配置 |

---

## 10. 配置建议

### 当前配置 (有问题)

```toml
[models]
default = "glm-5-2"
image_description = "glm-5-2"   # ← GLM 不支持图片,describe 会失败
```

### 建议配置

```toml
[model.glm-5-2]
model = "GLM-5.2"
base_url = "https://ark.cn-beijing.volces.com/api/coding/v3"
api_backend = "chat_completions"
env_key = "SZ_ARK_API_KEY"
context_window = 512000
supports_image_input = false        # ← 新增

[model.grok-4.5]                    # ← 需要一个支持图片的模型
model = "grok-4.5"
# ... (配置省略,需要 API key)

[models]
default = "glm-5-2"
image_description = "grok-4.5"      # ← 改为支持图片的模型
```

**前提条件**:用户需要一个支持图片的模型(如 Grok-4.5)及其 API key,用于图片描述。如果没有,Layer 3(错误恢复)仍能避免报错,但模型无法获得图片内容。

---

## 11. 实施顺序

1. **Layer 3 先做** (错误匹配 + 占位符文本) - 改动最小,立即修复崩溃
2. **Layer 2 + Layer 1 后做** (能力标志 + describe 转发) - 让模型获得图片描述,而非简单丢弃

Layer 3 确保不再报错;Layer 1+2 让模型真正理解图片内容。


---

## 12. 实施记录 (2026-08-06)

所有三层方案已实施完成,编译通过,测试通过。

### 已完成的改动

**Layer 3 (错误恢复):**
- `error.rs`: `is_image_processing_error()` 添加 `|| message.contains("only support text")` 匹配
- `conversation.rs`: 占位符文本从 `"[image removed - conversation too large]"` 改为 `"[image content removed]"`
- 新增 2 个测试: `image_processing_error_text_only_model_400_detected`, `image_processing_error_text_only_model_500_wrapped`
- 更新 2 个测试断言: `test_strip_images_removes_user_images`, `test_strip_images_mixed_content_only_replaces_images`

**Layer 2 (模型能力标志):**
- `config.rs` (`ModelEntryConfig`): 添加 `supports_image_input: bool` 字段 (默认 true)
- `config.rs` (`DefaultModelJson`): 添加 `supports_image_input: bool` 字段
- `config.rs` (`ModelInfo`): 添加 `supports_image_input: bool` 字段
- `config.rs` (`ConfigModelOverride`): 添加 `supports_image_input: Option<bool>` 字段 + apply 逻辑
- `SamplerConfig` (`xai-grok-sampler/src/config.rs`): 添加 `supports_image_input: bool` 字段
- `AcpSessionImpl`: 添加 `supports_image_input: Cell<bool>` 字段
- `ModelsManager`: 添加 `model_supports_image_input()` 方法
- 所有构造点 (53 处) 已同步添加字段

**Layer 1 (跳过/Describe 转发):**
- `turn.rs`: 当 `supports_image_input=false` 时:
  - 配置了 `image_description` 视觉模型 -> 走 `transcribe_user_images` describe 流程
  - 未配置 -> 跳过图片,附加 `[N image(s) skipped]` 文本说明
- `tool_calls.rs`: `read_file` 读取图片时:
  - `supports_image_input=false` -> 不 inline 附加,返回 `[Image file {path} skipped]` 文本
  - `supports_image_input=false` -> PDF 页面图片也不 inline 附加

### 验证结果
- `cargo check --workspace`: 编译通过 (0 errors)
- `cargo test -p xai-grok-sampling-types -- image_processing`: 8/8 通过
- `cargo test -p xai-grok-sampling-types -- strip_images`: 7/7 通过

### 用户配置示例

**场景 1: 跳过图片 (不识别)**
```toml
[model.glm-5-2]
supports_image_input = false

[models]
default = "glm-5-2"
# 不配置 image_description
```

**场景 2: 视觉模型识别转发**
```toml
[model.glm-5-2]
supports_image_input = false

[model.grok-4.5]
# 支持图片的模型 (默认 supports_image_input = true)

[models]
default = "glm-5-2"
image_description = "grok-4.5"
```

**场景 3: 原有行为 (支持图片的模型)**
```toml
[model.grok-4.5]
# 默认 supports_image_input = true,无需配置

[models]
default = "grok-4.5"
```
