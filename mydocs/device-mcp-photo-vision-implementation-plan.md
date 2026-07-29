# Android 设备 MCP 拍照视觉理解 — 实现方案

> 日期：2026-07-29
> 分类：plan
> 状态：待实施

## 1. 目标

把现有 `phone.take_photo` / `self.camera.take_photo` 从“拍照并保存到本地相册”升级为：

> Android 自动拍照 → 上传到 Cloudflare Worker `/vision/explain` → Worker 存入 R2 bucket 并完成图片视觉理解 → Android 将视觉理解文本作为 MCP `tools/call` 结果回给上游 → 上游 LLM 继续生成回复 → TTS 播报。

目标用户体验：用户说“帮我拍张照片看看”后，手机不会保存照片到本地相册，而是直接听到 AI 对当前画面的描述。

---

## 2. 核心结论

Cloudflare Worker 完成图片理解后，**必须把理解结果返回给 Android**，再由 Android 通过当前 MCP `tools/call` response 回给上游。

原因：当前语音链路依赖上游 LLM 收到工具结果后继续生成文本，随后才会进入 TTS 播放。如果 Worker 只在云端完成视觉理解但不把结果返回到本次工具调用，上游 LLM 没有工具结果可继续处理，通常不会产生 TTS 音频，用户也就听不到图片描述。

因此标准稳定链路是同步工具调用：

```text
LLM tools/call phone.take_photo
→ Android 拍照
→ Android POST /vision/explain
→ Worker 存 R2 + 视觉理解
→ Worker 返回视觉文本
→ Android 回 MCP tool result
→ 上游 LLM 生成回复
→ TTS 播报
```

---

## 3. 当前现状

### 3.1 Android 侧

当前文件：`lib/services/device_mcp_tools.dart`

现有 `TakePhotoTool` 流程：

1. 请求 `CAMERA` 权限。
2. 用 `camera` 包选择前置/后置摄像头。
3. `CameraController.takePicture()` 拍到临时文件。
4. 通过 MethodChannel `saveImageToGallery` 调用 Kotlin 原生 `MediaStore` 保存到本地相册。
5. 删除临时文件。
6. 返回文本：“已用前/后置摄像头拍照并保存到相册”。

当前文件：`android/app/src/main/kotlin/com/lhht/ai_assistant/MainActivity.kt`

已有原生方法：

- `saveImageToGallery`
- `saveImage(...)`

这些用于保存相册。新方案不再需要在拍照工具中调用它们，但可以先保留代码，避免影响其它潜在调用。

当前文件：`lib/services/xiaozhi_service.dart`

`_handleMcpMessage()` 已支持：

- `initialize`
- `tools/list`
- `tools/call`

当 `tools/call` 返回 `McpToolResult` 后，会回传：

```json
{
  "content": [{ "type": "text", "text": "..." }],
  "isError": false
}
```

这正好可以承载 Worker 返回的图片理解文本。

### 3.2 Worker 侧

根据 `mydocs/device-mcp-tools-plan.md`，Worker 侧已经规划或已有：

- `/vision/explain` 端点
- `vision.js`
- `attachVision` 管线
- 上传后视觉理解能力

本方案要求 Worker 的 `/vision/explain` 变成一个同步 HTTP 接口：Android 上传图片后，该接口完成存储和视觉理解，并直接返回文本结果。

---

## 4. 推荐架构

采用同步方案：Android 工具 handler 等待 Worker 返回视觉理解结果，再把结果回给 MCP 上游。

```text
用户语音
  ↓
xiaozhi 上游 LLM
  ↓ tools/call: phone.take_photo / self.camera.take_photo
Android TakePhotoTool
  ↓ camera.takePicture()
临时 JPEG 文件
  ↓ multipart POST /vision/explain
Cloudflare Worker
  ↓ put R2 bucket
Cloudflare R2
  ↓ vision explain
图片描述文本
  ↓ HTTP response JSON
Android TakePhotoTool
  ↓ McpToolResult(success=true, text=视觉描述)
MCP tools/call response
  ↓
上游 LLM
  ↓
TTS 播报
```

---

## 5. Android 侧实现方案

### 5.1 修改 `phone.take_photo` 的工具说明

文件：`lib/services/device_mcp_tools.dart`

将描述从“拍照并保存到相册”改为“拍照并上传云端做视觉理解”。

建议描述：

```text
使用手机摄像头拍一张照片，不保存到本地相册，而是上传到云端进行视觉理解，并返回图片内容描述。
可选参数 camera 指定使用后置(back)或前置(front)摄像头，默认 back。
用于用户说“帮我拍张照片看看 / 看看这是什么 / 识别一下画面 / 用前置看看我”等场景。
```

`inputSchema` 可以保持不变：

```json
{
  "camera": "back | front"
}
```

后续如需要可增加 `prompt` 参数，让上游指定视觉问题；第一版不建议加，保持简单稳定。

### 5.2 新增 Worker 视觉接口配置

Android 需要知道上传地址和认证信息。

建议放在已有配置常量附近，例如 `config_provider.dart` 中已有：

```dart
WORKER_BASE = 'https://xiaozhi-myapp.weikaizhan80.workers.dev'
```

新增：

```dart
static const String WORKER_VISION_EXPLAIN_URL = '$WORKER_BASE/vision/explain';
```

如果 Worker 需要 token，也应复用 OTA 或 initialize 中已有的 vision token 机制。若当前 Worker 已在服务端 `initialize` 中告诉设备 `/vision/explain` 端点和 token，后续可以把该能力做成运行时配置；第一版可先使用固定 Worker URL，认证方式由 Worker 端接口决定。

推荐认证方式优先级：

1. 复用 Worker OTA / WebSocket token：请求头 `Authorization: Bearer <token>`。
2. 使用 Worker 自定义短 token：请求头 `X-Vision-Token: <token>`。
3. 仅开发测试阶段允许无认证，生产不推荐。

### 5.3 改造 `TakePhotoTool.call()` 流程

旧流程：

```text
拍照 → saveImageToGallery → 删除临时文件 → 返回相册保存结果
```

新流程：

```text
拍照 → 上传临时文件到 /vision/explain → 删除临时文件 → 返回视觉理解文本
```

伪流程：

```dart
final xfile = await controller.takePicture();
try {
  final visionText = await uploadPhotoForVision(
    filePath: xfile.path,
    camera: useFront ? 'front' : 'back',
  );
  return McpToolResult(true, visionText);
} finally {
  await File(xfile.path).delete();
}
```

### 5.4 新增上传 helper

建议不要把 multipart 细节全部堆在 `TakePhotoTool.call()` 中，而是拆出私有方法或新类，例如：

```dart
class VisionExplainClient {
  Future<String> explainImage({
    required String filePath,
    required String camera,
  });
}
```

第一版也可以先在 `device_mcp_tools.dart` 内部实现私有方法，后续再拆。

职责：

1. 读取临时 JPEG 文件。
2. multipart POST 到 Worker `/vision/explain`。
3. 设置超时，例如连接 + 总等待 20 秒。
4. 解析 JSON 响应。
5. 返回最终可给 LLM/TTS 使用的中文描述文本。

建议 HTTP 请求：

```http
POST /vision/explain
Content-Type: multipart/form-data
Authorization: Bearer <token>   # 如果启用认证

fields:
  image: <jpeg file>
  camera: back | front
  device_id: <mac/client id，可选>
  source: android-mcp
```

Dart 依赖选择：

- 如果项目已有 `http` 包，使用 `package:http/http.dart` 的 `MultipartRequest`。
- 如果没有，需要在 `pubspec.yaml` 增加 `http` 依赖。

### 5.5 Android 期望解析的 Worker 响应

推荐 Worker 成功响应：

```json
{
  "ok": true,
  "text": "画面中有一张桌子，桌上放着一杯咖啡和一本书。",
  "imageKey": "vision/2026/07/29/<uuid>.jpg",
  "imageUrl": "https://...", 
  "model": "...",
  "elapsedMs": 1234
}
```

Android 只依赖：

- `ok`
- `text`

其它字段仅日志使用。

如果失败：

```json
{
  "ok": false,
  "error": "vision_model_failed",
  "message": "视觉理解失败，请稍后再试"
}
```

Android 对失败响应转换为：

```dart
McpToolResult(false, '拍照成功，但云端视觉理解失败：$message')
```

`isError=true` 会回到上游，LLM 通常会向用户解释失败原因并触发 TTS。

### 5.6 返回给上游的文本策略

为了让上游 LLM 更容易产生自然播报，Android 的工具结果建议直接返回 Worker 的视觉文本，不要只返回“上传成功”。

推荐成功工具结果：

```text
图片视觉理解结果：画面中有一张桌子，桌上放着一杯咖啡和一本书。
```

也可以直接返回：

```text
画面中有一张桌子，桌上放着一杯咖啡和一本书。
```

推荐第一版使用前者，便于上游明确这是工具观察结果。

### 5.7 不保存本地相册

新 `TakePhotoTool` 不再调用：

```dart
channel.invokeMethod('saveImageToGallery', ...)
```

拍照临时文件只用于上传，上传成功或失败后都要尽量删除：

```dart
try { await File(xfile.path).delete(); } catch (_) {}
```

注意：失败时也不保存相册，除非后续用户明确要求“失败时保底保存本地”。当前目标是不保存本地相册。

---

## 6. Worker 侧实现方案

### 6.1 `/vision/explain` 接口职责

Worker 接口应同步完成：

1. 接收 Android 上传的 multipart 图片。
2. 校验认证和文件类型/大小。
3. 将图片写入 Cloudflare R2 bucket。
4. 调用视觉模型或现有视觉管线读取图片。
5. 返回视觉理解文本给 Android。

接口不是只负责上传，也不是异步任务接口；第一版应保持同步返回，确保 MCP 工具调用链路闭环。

### 6.2 请求格式

推荐：

```http
POST https://<worker>/vision/explain
Authorization: Bearer <token>
Content-Type: multipart/form-data
```

字段：

| 字段 | 必填 | 说明 |
|------|------|------|
| `image` | 是 | JPEG 图片文件 |
| `camera` | 否 | `back` 或 `front` |
| `device_id` | 否 | Android 设备 ID/MAC，用于日志和对象 key |
| `source` | 否 | 固定 `android-mcp` |

### 6.3 R2 存储设计

使用已有 R2 bucket：**`xiaozhi-capture`**。

R2 key 格式：

```text
vision/yyyy/mm/dd/<device-id-or-anon>/<timestamp>-<uuid>.jpg
```

例如：

```text
vision/2026/07/29/android-abc123/1722250000000-f3a2.jpg
```

R2 metadata 可记录（bucket: `xiaozhi-capture`）：

- `device_id`
- `camera`
- `source=android-mcp`
- `content_type=image/jpeg`
- `created_at`

是否公开访问：

- 第一版不需要公开图片 URL。
- Worker 自己能从 R2 读取即可。
- 如果返回 `imageUrl`，应确保是短期签名 URL 或仅调试用 URL，避免隐私泄露。

### 6.4 图片大小限制

Worker 应限制上传大小，避免手机误传大文件或被滥用。

建议第一版限制：

- Content-Type：`image/jpeg`、可兼容 `image/png`。
- 大小：最大 5MB。
- Android 侧使用 `ResolutionPreset.medium` 已经较合适。

失败返回：

```json
{
  "ok": false,
  "error": "file_too_large",
  "message": "图片太大，无法上传分析"
}
```

### 6.5 视觉理解实现方式

Worker 内部可以使用现有 `vision.js` / `attachVision` 管线。

抽象目标是暴露一个函数：

```js
async function explainImageFromR2(env, key, options) {
  // 读取 R2 对象或生成可访问 URL
  // 调用视觉模型
  // 返回中文描述文本
}
```

也可以直接对上传的 ArrayBuffer 调视觉模型，再存 R2；但本项目目标提到“上传到 Cloudflare bucket 里，然后在 Cloudflare 进行图片视觉理解的读取”，所以推荐顺序是：

```text
multipart image → R2 put → R2 get / signed URL / object body → vision explain
```

### 6.6 Worker 响应格式

成功：

```json
{
  "ok": true,
  "text": "画面中有一只白色杯子放在桌面上，旁边有一台笔记本电脑。",
  "imageKey": "vision/2026/07/29/android-abc123/1722250000000-f3a2.jpg",
  "elapsedMs": 1800
}
```

失败：

```json
{
  "ok": false,
  "error": "vision_failed",
  "message": "视觉理解失败，请稍后再试"
}
```

### 6.7 Worker 超时控制

MCP 工具调用不宜等待太久，否则用户会感觉卡住。

建议目标：

- 正常响应：3–8 秒。
- Android 总超时：20 秒。
- Worker 内部视觉模型超时：15 秒左右。

如果超时，Worker 返回失败 JSON，Android 回 `McpToolResult(false, ...)`，让上游 TTS 播报失败提示。

---

## 7. 端到端协议闭环

### 7.1 成功链路

上游发起 MCP 工具调用：

```json
{
  "method": "tools/call",
  "params": {
    "name": "phone.take_photo",
    "arguments": { "camera": "back" }
  }
}
```

Android 执行：

```text
拍照 → 上传 Worker → 得到视觉文本
```

Android 回 MCP：

```json
{
  "result": {
    "content": [
      {
        "type": "text",
        "text": "图片视觉理解结果：画面中有一张桌子，桌上有一杯咖啡和一本书。"
      }
    ],
    "isError": false
  }
}
```

上游 LLM 收到该工具结果后，继续回复：

```text
我看到了桌子上有一杯咖啡和一本书，旁边像是一台笔记本电脑。
```

随后 TTS 播放。

### 7.2 失败链路

如果拍照成功但 Worker 失败：

```json
{
  "result": {
    "content": [
      {
        "type": "text",
        "text": "拍照成功，但云端视觉理解失败：请求超时，请稍后再试。"
      }
    ],
    "isError": true
  }
}
```

上游 LLM 应播报类似：

```text
我拍到了照片，但云端识别超时了，你可以稍后再试一次。
```

如果相机权限失败，则保持当前错误逻辑：

```text
没有相机权限，无法拍照
```

---

## 8. 错误处理策略

| 场景 | Android 行为 | Worker 行为 | 用户体验 |
|------|--------------|-------------|----------|
| 无相机权限 | 不拍照，返回 `isError=true` | 无请求 | TTS 提示没有权限 |
| 无摄像头 | 返回 `isError=true` | 无请求 | TTS 提示设备无摄像头 |
| 拍照失败 | 返回 `isError=true` | 无请求 | TTS 提示拍照失败 |
| 上传失败 | 删除临时文件，返回 `isError=true` | 可能无日志 | TTS 提示上传失败 |
| Worker 认证失败 | 返回 `isError=true` | 返回 401/403 JSON | TTS 提示视觉服务认证失败 |
| 图片过大 | 返回 `isError=true` | 返回 `file_too_large` | TTS 提示图片太大 |
| R2 写入失败 | 返回 `isError=true` | 返回 `r2_put_failed` | TTS 提示云端保存失败 |
| 视觉模型失败 | 返回 `isError=true` | 返回 `vision_failed` | TTS 提示识别失败 |
| 视觉超时 | 返回 `isError=true` | 返回 `timeout` | TTS 提示超时 |

无论成功失败，Android 都要尽量删除临时文件。

---

## 9. 日志建议

### Android 日志

建议沿用 `[xz_dbg]` 风格：

```text
[xz_dbg] phone.take_photo: start camera=back
[xz_dbg] phone.take_photo: captured path=... size=...
[xz_dbg] phone.take_photo: uploading to /vision/explain
[xz_dbg] phone.take_photo: vision ok elapsed=1234ms textLen=56
[xz_dbg] phone.take_photo: temp deleted
```

错误：

```text
[xz_dbg] phone.take_photo: vision failed error=timeout message=...
```

注意不要在日志中打印完整图片内容或敏感 token。

### Worker 日志

建议记录：

```text
[vision] request start device=... camera=back size=...
[vision] r2 put key=... elapsed=...
[vision] explain ok model=... elapsed=... textLen=...
[vision] request failed error=...
```

---

## 10. 安全与隐私

1. 默认不保存到 Android 本地相册。
2. 图片会上传到 Cloudflare R2，应明确这是云端处理。
3. Worker 接口需要认证，避免任何人上传图片消耗资源。
4. R2 bucket 不建议公开读。
5. 如需返回图片 URL，使用短期签名 URL，不要返回永久公开 URL。
6. Worker 应限制文件大小和 MIME 类型。
7. 日志不要打印 token、完整 URL 签名或图片二进制内容。
8. 如后续需要清理隐私数据，可加 R2 生命周期规则，例如保留 1–7 天自动删除。

---

## 11. 测试计划

### 11.1 Android 单侧测试

1. 调用 `phone.take_photo`，确认不会调用 `saveImageToGallery`。
2. 拍照后临时文件能被删除。
3. Worker 返回 mock 成功 JSON 时，MCP tool result 文本正确。
4. Worker 返回失败 JSON 时，`isError=true` 且错误文本清晰。
5. 网络断开时，返回上传失败而不是卡死。

### 11.2 Worker 单侧测试

使用 curl 或 Postman 上传一张本地图片：

```bash
curl -X POST https://<worker>/vision/explain \
  -H "Authorization: Bearer <token>" \
  -F "image=@test.jpg" \
  -F "camera=back" \
  -F "source=android-mcp"
```

确认：

1. R2 中出现对象。
2. 响应 JSON `ok=true`。
3. `text` 是可直接播报的中文图片描述。
4. 大文件、错误 MIME、缺 token 都能返回明确错误。

### 11.3 端到端语音测试

用 Android worker 模式语音触发：

```text
帮我拍张照片看看
```

预期：

1. LLM 调用 `phone.take_photo` 或 `self.camera.take_photo`。
2. Android 自动拍照。
3. 本地相册不新增图片。
4. Worker 收到 `/vision/explain` 请求。
5. R2 有图片对象。
6. Android MCP tool result 回传视觉描述。
7. 上游 LLM 生成回复。
8. TTS 播报图片描述。

---

## 12. 实施步骤建议

### 阶段 1：Worker mock 接口

先让 `/vision/explain` 接收图片并返回固定文本：

```json
{
  "ok": true,
  "text": "我已经收到图片，这是一条测试视觉描述。"
}
```

用于验证 Android 上传 + MCP/TTS 闭环。

### 阶段 2：Android 改造上传

改 `TakePhotoTool`：

1. 去掉保存相册调用。
2. 拍照后 multipart 上传。
3. 解析 Worker mock 响应。
4. 回 MCP tool result。
5. 验证 TTS 能播报 mock 文本。

### 阶段 3：Worker 接入 R2

`/vision/explain` 写入已有 R2 bucket `xiaozhi-capture`，返回 `imageKey`，仍可先返回 mock 文本。

### 阶段 4：Worker 接入真实视觉理解

Worker 从 R2 读取图片，调用现有 `vision.js` / `attachVision` 管线，返回真实图片描述。

### 阶段 5：优化与清理

1. 增加超时与错误映射。
2. 增加日志。
3. 增加 R2 生命周期规则。
4. 更新 `mydocs/device-mcp-tools-plan.md`：阶段四从“后续”改为“已实施/实施中”，并修正拍照工具不再保存相册。

---

## 13. 待确认点

1. Worker `/vision/explain` 当前是否已经存在可用实现，还是需要从 mock 开始补。
2. Worker 视觉模型使用哪一个 provider，以及返回文本语言是否强制中文。
3. Android 上传认证使用哪种 token：WebSocket token、专用 vision token，还是开发阶段无认证。
4. R2 图片保留时间：永久保留、保留 1 天、保留 7 天，或后续手动清理。

当前推荐默认：

- 第一版同步接口。
- Android 不保存相册。
- Worker 先 mock 跑通闭环，再接 R2，再接真实视觉。
- 返回中文视觉描述文本给 Android，再由 Android 回 MCP tool result，确保 TTS 播报。
