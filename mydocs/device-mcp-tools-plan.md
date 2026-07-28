# Android 设备 MCP 工具 — 实现规划

> 让 Android 手机变成 **MCP 工具服务端**，xiaozhi 服务端（经自建 Worker）的 LLM 能在对话中调用手机能力。
> 例：用户说"帮我拍张照片" → LLM 调用拍照工具 → 手机拍照保存 → AI 回复确认。

---

## 一、现状（骨架已就绪）

做自建 Worker 连接时，已经搭好了设备侧 MCP 服务端骨架（`lib/services/xiaozhi_service.dart` 的 `_handleMcpMessage`）：

| MCP 方法 | 行为 |
|----------|---------|
| `initialize` | 回协议信息 ✓ |
| `tools/list` | 返回设备注册的工具（注册表 `DeviceMcpTools`） |
| `tools/call` | 按工具名派发执行，回结果 |

- hello 已声明 `features.mcp: true`，MCP 握手链路已通（日志验证过）。
- Worker（`proxy.js`）会把设备返回的 `tools/list` 转给上游 LLM，并额外**注入自己的工具**（如 `self.camera.take_photo`）追加进列表。
- 服务端 `initialize` 会把 **vision 能力 + `/vision/explain` 端点**告诉设备（为阶段四视觉铺路）。

---

## 二、架构：可扩展的工具注册表

不写死工具，做成注册表，新增工具只需注册一条、不动协议代码：

```
McpTool（抽象）
  ├─ name         工具名（给 LLM 调用）
  ├─ description  给 LLM 看的说明（决定 LLM 何时触发）
  ├─ inputSchema  参数 JSON Schema
  └─ handler      (arguments) → 执行 → 返回结果（文本/图片）

tools/list  → 把注册表序列化成 MCP tools 数组
tools/call  → 按 payload.params.name 派发到对应 handler，执行，回 {result} 或 {error}
```

`lib/services/device_mcp_tools.dart` 是注册表；新工具 = 新增一个 `McpTool` 子类 + 在构造里 `_register(...)`。

---

## 三、阶段一：拍照工具（已完成）✅

### 工具定义

- **name**: `phone.take_photo`（`self.camera.take_photo` 别名到同一 handler）
- **description**: 用手机摄像头拍一张照片并保存到相册（不弹相机 UI）
- **inputSchema**: `{ camera: back|front（默认 back） }`
- **返回**：文本，如"已用后置摄像头拍照并保存到相册：IMG_xxx.jpg"

### 实现要点

- `camera` 包程序化拍照（`CameraController` + `takePicture`，无预览）。
- 存相册：MethodChannel `saveImageToGallery` → 原生 MediaStore（`DCIM/Camera`）。
- 权限：`CAMERA`（运行时申请）。
- 已实测：worker 模式说"拍张照片"触发拍照并存相册。

---

## 四、阶段二：闹钟（已完成）✅

### 4.1 工具定义

- **name**: `phone.set_alarm`
- **description**: "设置一个系统闹钟（写入手机时钟 App），到点按系统闹钟方式响铃（震动+铃声，锁屏/重启/App被杀都能响）。适合'帮我设 X 点的闹钟'或'X 分钟后提醒我'。可选 label 备注。"
- **inputSchema**（`time` 与 `minutes` 二选一）:
  ```json
  {
    "time":    { "type": "string", "description": "绝对时间 HH:MM（24h），如 \"19:00\"" },
    "minutes": { "type": "number", "description": "相对分钟数（从现在起），如 5" },
    "label":   { "type": "string", "description": "闹钟备注/名称（可选，显示在时钟 App 里）" }
  }
  ```
- **返回**：文本，如"已设置系统闹钟：19:00 吃饭，可在时钟 App 查看"。

### 4.2 实现（系统时钟 App，ACTION_SET_ALARM）

- handler 把 `time`/`minutes` 算成 `hour, minute`（设备本地时钟，相对分钟也能算）。
- MethodChannel `setSystemAlarm(hour, minute, label)` → Kotlin 发 `AlarmClock.ACTION_SET_ALARM` 意图：
  `EXTRA_HOUR` / `EXTRA_MINUTES` / `EXTRA_MESSAGE`(label) / `EXTRA_VIBRATE=true` / `EXTRA_SKIP_UI=true`。
- 系统时钟 App 收到意图 → 写入真闹钟。工具立即返回确认文本。
- 权限：`com.android.alarm.permission.SET_ALARM`（普通权限，安装即授）。

### 4.3 实测结果（小米 HyperOS）

- ✅ `EXTRA_SKIP_UI` **被遵守**：时钟 App 用 `HandleSetAlarmActivity`（无界面处理器）静默写入闹钟后**自动 finish**，回到 AI-LHHT，AI 继续说话（日志：llm → tts）。不会弹全屏闹钟编辑界面。
- ✅ 闹钟写入系统时钟 App，可在时钟 App 查看/管理；锁屏/重启/App 被杀都能响。
- ✅ 语音触发整链路通：STT → LLM → `tools/call phone.set_alarm` → `setSystemAlarm` → 时钟 App。
- 原"前台 Timer"方案已废弃删除（App 被杀就失效，不可靠）。
- ⚠️ 文本输入走 `detect` 会被 tenclass 拒长文本，**闹钟须用语音触发**。极少数设备时钟 App 不处理 `ACTION_SET_ALARM` → `ActivityNotFoundException`，handler 已捕获返回错误文本。

---

## 五、阶段三：手电筒 / 位置（后续）

| 工具 | name | 说明 | 权限 |
|------|------|------|------|
| 手电筒 | `phone.torch` | 开/关手电筒，参数 `on: bool` | `FLASHLIGHT`（一般免申请） |
| 当前位置 | `phone.get_location` | 返回 GPS 经纬度（可选反查地址） | `ACCESS_FINE_LOCATION` |

---

## 六、权限汇总（随工具逐步加）

- 拍照：`CAMERA` ✓
- 闹钟（系统时钟 App）：`com.android.alarm.permission.SET_ALARM` ✓
- 位置：`ACCESS_FINE_LOCATION`（后续）

均在 `AndroidManifest.xml` 声明 + 运行时申请（复用 `permission_handler`）。

---

## 七、视觉（阶段四，更后续）

拍照后让 AI **看图描述** —— 服务端 `initialize` 已主动把 `/vision/explain` 端点 + token 告诉设备。拍照后把 JPEG 以 multipart POST 到该端点即可让 AI 看图（Worker 已有 `vision.js` + `attachVision` 管线）。本期不做。

---

## 八、阶段计划

- **阶段一（已完成）**：拍照 `phone.take_photo`（程序化拍照 + 存相册 + 文本回传），打通 tools/list + tools/call 注册表。
- **阶段二（已完成）**：闹钟 `phone.set_alarm`（系统时钟 App，ACTION_SET_ALARM，实测语音触发可用）。
- **阶段三**：手电筒、位置（简单工具）。
- **阶段四**：视觉（拍照回传 AI 看图）。
