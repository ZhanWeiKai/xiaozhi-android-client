# Android 设备 MCP 工具 — 实现规划

> 让 Android 手机变成 **MCP 工具服务端**，xiaozhi 服务端（经自建 Worker）的 LLM 能在对话中调用手机能力。
> 例：用户说"帮我拍个照" → LLM 调用拍照工具 → 手机拍照保存 → AI 回复确认。

---

## 一、现状（骨架已就绪）

做自建 Worker 连接时，已经搭好了设备侧 MCP 服务端骨架（`lib/services/xiaozhi_service.dart` 的 `_handleMcpMessage`）：

| MCP 方法 | 当前行为 | 本次目标 |
|----------|---------|---------|
| `initialize` | 回协议信息 ✓ | 不变 |
| `tools/list` | 返回空 `[]` | **填入真实工具** |
| `tools/call` | 一律回 `-32601` | **按工具名派发执行** |

- hello 已声明 `features.mcp: true`，MCP 握手链路已通（日志验证过）。
- Worker（`proxy.js`）会把设备返回的 `tools/list` 转给上游 LLM，并额外**注入自己的工具**（如 `self.camera.take_photo`）追加进列表。

---

## 二、架构：可扩展的工具注册表

不写死工具，做成注册表，新增工具只需注册一条、不动协议代码：

```
McpTool（抽象）
  ├─ name         工具名（给 LLM 调用）
  ├─ description  给 LLM 看的说明
  ├─ inputSchema  参数 JSON Schema
  └─ handler      (params) → 执行 → 返回结果（文本/图片）

tools/list  → 把注册表序列化成 MCP tools 数组
tools/call  → 按 payload.params.name 派发到对应 handler，执行，回 {result} 或 {error}
```

---

## 三、第一阶段：拍照工具（先做这个）⭐

### 3.1 工具定义

- **name**: `phone.take_photo`
- **description**: "用手机摄像头拍一张照片并保存到相册"
- **inputSchema**:
  ```json
  { "camera": { "type": "string", "enum": ["back", "front"], "default": "back" } }
  ```
- **返回**：文本，如 `已拍照并保存到相册：IMG_20260728_123456.jpg`

### 3.2 实现要点

- **程序化拍照**（不弹系统相机 UI，LLM 触发即拍）：用 `camera` 包初始化 `CameraController` + `takePicture()`。不用 `image_picker`（它要用户手动按快门，不够自主）。
- **保存到相册**：写入 MediaStore（`DCIM/Camera`），Android 10+ 免 `WRITE_EXTERNAL_STORAGE` 权限。
- **权限**：`CAMERA`（运行时申请，复用现有权限框架）。
- **派发**：`_handleMcpMessage` 的 `tools/call` 分支，识别 `phone.take_photo` → 调相机 handler → 把结果文本包进 MCP `{result: {content:[{type:"text", text:"..."}]}}` 回传（原样带 `session_id` 和 `payload.id`）。

### 3.3 待确认 / 注意

- **工具名冲突**：Worker 注入的 `self.camera.take_photo` 会和设备 `phone.take_photo` 同时出现在 `tools/list`。建议在 dispatcher 里把 `self.camera.take_photo` 也**别名**到同一 handler，避免 LLM 调到注入的那个时设备返回 -32601。（实现时实测 LLM 实际调哪个）
- **首次相机初始化慢**：需异步 + 超时保护（如 8s 超时则回错误文本，不让上游挂起）。
- **通话中拍照**：App 在语音通话界面时，相机抢占/预览行为需实测（可能需要无预览或最小预览）。
- **结果回传**：先纯文本；图片返回（让 AI 看图）属"视觉"，见第六节。

---

## 四、后续工具（仅记录，本期不实现）

| 工具 | name | 说明 | 权限 |
|------|------|------|------|
| 手电筒 | `phone.torch` | 开/关手电筒，参数 `on: bool` | `FLASHLIGHT`（一般免申请） |
| 当前位置 | `phone.get_location` | 返回 GPS 经纬度（可选反查地址） | `ACCESS_FINE_LOCATION` |
| 闹钟/提示音 | `phone.set_alarm` | "帮我设 X 点闹钟，到点震动提示音" | 见下 |

### 闹钟/提示音（需进一步确认）

用户期望："帮我设几点的闹钟，到点有震动提示音"。两条实现路线：

- **演示级**：`Timer` 实现，**仅 App 在前台/内存有效**，被杀则失效。简单。
- **真闹钟**：`flutter_local_notifications` 的 `zonedSchedule` + 安卓 `SCHEDULE_EXACT_ALARM` 精确闹钟权限 + 通知权限，**后台/锁屏也能响**。复杂但实用。

→ 触发场景（是否需要后台存活）待用户确认后再定方案。

---

## 五、权限汇总（随工具逐步加）

- 拍照：`CAMERA`
- 位置：`ACCESS_FINE_LOCATION`
- 闹钟（真闹钟）：`SCHEDULE_EXACT_ALARM`、通知权限
- 震动：`VIBRATE`

均在 `AndroidManifest.xml` 声明 + 运行时申请（复用 `permission_handler`）。

---

## 六、视觉（更后续，不在本期）

拍照后让 AI **看图描述** —— 需服务端支持 MCP `image` 内容返回，或走 Worker 的 `/vision/explain`（Worker 已有 `vision.js` + `attachVision` 视觉管线，但那是 ESP32 相机的 multipart 协议，Android 要单独适配）。本期拍照仅保存 + 文本确认。

---

## 七、阶段计划

- **阶段一（本次）**：拍照工具 `phone.take_photo`（程序化拍照 + 存相册 + 文本回传），打通 tools/list + tools/call 注册表。
- **阶段二**：手电筒、位置（简单工具）。
- **阶段三**：闹钟/提示音（先定触发场景）。
- **阶段四**：视觉（拍照回传 AI 看图）。
