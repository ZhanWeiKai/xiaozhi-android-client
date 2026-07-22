# 自建 Worker 连接方式 — 实现文档

> 参考来源：`C:\claude-project\cloud-flare-study\demo\xiaozhi-dev-2\xiaozhi-dev-2\public\simulate.html`
> Worker 项目：`cloud-flare-study/demo/xiaozhi-dev-2`（worker 名 `xiaozhi-myapp`，部署在 workers.dev，本质是代理到官方 `api.tenclass.net` 的中间层）

本文档说明「自建 Worker」这种新的小智服务连接方式，**完全对齐 simulate.html 的连接行为**，并在现有 `official` / `custom` 两种模式基础上新增第三种。

---

## 一、一句话概括

simulate.html 连 Worker 的方式 = **OTA 拿 token + wsUrl → 用 URL query params 认证连 WebSocket → 发带 `features.mcp` 的 hello → 作为 MCP 服务端响应上游的 `initialize` / `tools/list` / `tools/call`**。

它和现有的 `custom` 模式重合度约 90%，区别只有 3 处小补充（见第五节）。

---

## 二、写死的 URL 常量

simulate.html 里：

```js
const WORKER_BASE = window.location.origin;          // Worker 自己的域名
const OTA_URL     = `${WORKER_BASE}/xiaozhi/ota/`;    // OTA 注册接口
```

Android 客户端没有「当前页面 origin」，所以**把 Worker 域名写死成一个常量**，OTA 路径固定为 `/xiaozhi/ota/`：

```dart
// config_provider.dart
static const String WORKER_BASE    = 'https://xiaozhi-myapp.weikaizhan80.workers.dev'; // 已写死，simulate.html 同源
static const String WORKER_OTA_URL = '${WORKER_BASE}/xiaozhi/ota/';
```

> 即打开 `https://xiaozhi-myapp.weikaizhan80.workers.dev/simulate.html` 时浏览器的 origin。
> WebSocket 地址 **不写死**，由 OTA 返回的 `websocket.url` 决定。

---

## 三、连接流程（两步）

### 第 1 步：OTA 注册（simulate.html 第 210–221 行）

```
POST {WORKER_OTA_URL}                       # https://<worker>/xiaozhi/ota/
Headers:
  Content-Type:    application/json
  Device-Id:       <MAC>
  Client-Id:       <UUID>
  dm:              floki                     # 模型，固定 floki
  Accept-Language: zh-CN                     # 语言

Body (与现有 _registerDevice 的 payload 完全一致):
{
  "version": 2, "flash_size": 16777216, "psram_size": 0,
  "minimum_free_heap_size": 8318916,
  "mac_address": "<MAC>", "uuid": "<UUID>",
  "chip_model_name": "esp32s3",
  "chip_info": { "model": 9, "cores": 2, "revision": 2, "features": 18 },
  "application": { "name": "xiaozhi", "version": "1.1.2", "idf_version": "v5.3.2" },
  "partition_table": [], "ota": { "label": "factory" },
  "board": { "type": "bread-compact-wifi", "ip": "", "mac": "<MAC>" }
}

返回 JSON:
{
  "websocket": {
    "url":   "wss://...",     # ← WebSocket 地址（运行时拿到）
    "token": "..."            # ← 认证 token
  },
  "mqtt": { "client_id": "..." }   # pool 信息（仅日志用）
}
```

> 现有 `_registerDevice()` 已经发同样的 body，**只需在 headers 上补 `dm` 和 `Accept-Language` 两个**。

### 第 2 步：连 WebSocket（simulate.html 第 236–237 行）

**认证全部走 URL query params，不用 headers**：

```
wss://<websocket.url>?authorization=Bearer%20<token>&device-id=<MAC>&client-id=<UUID>&dm=floki&lang=zh-CN
```

注意 token 里的空格要编码成 `%20`。

### 连上后：发 hello（simulate.html 第 248–255 行）

```json
{
  "type": "hello",
  "version": 3,
  "features": { "mcp": true },                       // ← 声明支持 MCP，触发上游握手
  "audio_params": { "format": "opus", "sample_rate": 16000, "channels": 1, "frame_duration": 60 },
  "device_id":   "<MAC>",
  "device_name": "xiaozhi-android",
  "device_mac":  "<MAC>",
  "token":       "<token>"
}
```

### 心跳：每 30 秒（simulate.html 第 259–263 行）

```json
{ "type": "heartbeat" }
```

---

## 四、MCP 握手（关键 ⭐ 之前遗漏的部分）

因为 hello 里声明了 `features.mcp = true`，**上游会主动发起 MCP 握手**——此时上游是 MCP **客户端**，我们的设备/客户端是 MCP **服务端**，必须回应上游发来的 JSON-RPC 请求，否则上游会一直挂起等待（卡死）。

simulate.html 第 282–337 行完整处理了 4 种情况。每条响应**必须原样回传请求里的 `session_id` 和 `payload.id`**，上游靠这两个字段匹配请求/响应。

### 4.1 `initialize`（必须响应）

```jsonc
// ← 上游请求
{ "type": "mcp", "session_id": "<sid>",
  "payload": { "jsonrpc": "2.0", "id": <id>, "method": "initialize", "params": {...} } }

// → 设备响应
{ "type": "mcp", "session_id": "<sid>",
  "payload": { "jsonrpc": "2.0", "id": <id>,
    "result": {
      "protocolVersion": "2024-11-05",
      "capabilities": { "tools": {} },
      "serverInfo": { "name": "xiaozhi-android", "version": "1.1.2" }
    }
  }
}
```

### 4.2 `tools/list`（必须响应，返回空列表）

```jsonc
// ← 上游请求
{ "type": "mcp", "session_id": "<sid>",
  "payload": { "jsonrpc": "2.0", "id": <id>, "method": "tools/list" } }

// → 设备响应：空 tools，Worker 代理会在这一步注入它自己的工具
{ "type": "mcp", "session_id": "<sid>",
  "payload": { "jsonrpc": "2.0", "id": <id>, "result": { "tools": [] } } }
```

> 设备本身不暴露任何工具，所以返回空数组。Worker 代理会把它自己的工具（如 `self.camera.take_photo`）追加进这个响应再转给 LLM。

### 4.3 `tools/call`（必须响应，方法不存在错误）

```jsonc
// ← 上游请求
{ "type": "mcp", "session_id": "<sid>",
  "payload": { "jsonrpc": "2.0", "id": <id>, "method": "tools/call",
               "params": { "name": "xxx", "arguments": {...} } } }

// → 设备响应：没有该工具，返回 -32601（仍必须回答，避免上游挂起）
{ "type": "mcp", "session_id": "<sid>",
  "payload": { "jsonrpc": "2.0", "id": <id>,
    "error": { "code": -32601, "message": "Unknown tool: xxx" } } }
```

### 4.4 其它带 `id` 的请求（必须响应，方法未找到）

```jsonc
// → 统一回 method not found
{ "type": "mcp", "session_id": "<sid>",
  "payload": { "jsonrpc": "2.0", "id": <id>,
    "error": { "code": -32601, "message": "Method not found: <method>" } } }
```

### 4.5 通知（无 `id`）：不回答，仅记录日志即可。

---

### 响应构造要点

| 字段 | 取值 |
|------|------|
| `type` | 固定 `"mcp"` |
| `session_id` | **原样回传**请求里的 `session_id` |
| `payload.jsonrpc` | 固定 `"2.0"` |
| `payload.id` | **原样回传**请求里的 `payload.id`（数字） |
| `payload.result` / `payload.error` | 二选一，按上面 4 种情况 |

> ⚠️ **现有 Android 客户端 `_handleTextMessage()` 没有处理 `mcp` 类型消息**，只处理 `hello/stt/tts/llm/emotion`。
> 加「自建 Worker」模式必须新增 MCP 消息处理，否则连上后上游握手会卡住、拿不到回复。

---

## 五、与现有 official / custom 模式的对比

| 项目 | official（xiaozhi.me） | custom（自建 server） | **worker（自建 worker，新增）** |
|------|------------------------|------------------------|----------------------------------|
| OTA URL | `https://api.tenclass.net/xiaozhi/ota/` | 用户填写 | **写死** `<worker>/xiaozhi/ota/` |
| WS 地址来源 | 硬编码 `wss://api.tenclass.net/xiaozhi/v1/` | OTA 返回 | OTA 返回（同 custom） |
| WS 认证 | HTTP headers | query params | query params（同 custom） |
| WS query 参数 | — | `authorization/device-id/client-id` | **多 `dm` + `lang`** |
| OTA headers | `Device-Id/Client-Id` | 同左 | **多 `dm` + `Accept-Language`** |
| hello | 简单格式 | 含 device_id/mac/token | 含 device_id/mac/token **+ `features.mcp:true`** |
| MCP 握手 | ❌ 无 | ❌ 无 | **✅ 必须响应 initialize/tools/list/tools/call** |

**与 custom 的差异只有 3 处**：
1. WS query 多 `dm` + `lang`
2. OTA header 多 `dm` + `Accept-Language`
3. hello 多 `features.mcp` → 衍生出**必须处理 MCP 握手**（这是最大、最重要的新增工作）

---

## 六、Android 客户端实现要点

建议复用现有 `configType` 机制，新增第三个值 `"worker"`：

### 6.1 `xiaozhi_config.dart`
- `configType` 增加可选值 `"worker"`（其它字段复用现有结构，`otaUrl` 写死为 `WORKER_OTA_URL`）。

### 6.2 `config_provider.dart`
- 新增常量 `WORKER_BASE` / `WORKER_OTA_URL`（见第二节）。
- 新增方法 `addWorkerXiaozhiConfig(String name)`：`configType = "worker"`，自动生成 mac + clientId，OTA 写死。

### 6.3 `xiaozhi_websocket_manager.dart`
- `_registerDevice()`：当 `configType == "worker"` 时，OTA headers 加 `dm: floki` 和 `Accept-Language: zh-CN`。
- `connect()`：当 `configType == "worker"` 时，走 query params 认证（同 custom），但 `_buildAuthUrl` 要拼上 `&dm=floki&lang=zh-CN`。
- `_sendHelloMessage()`：当 `configType == "worker"` 时，hello 里加 `"features": { "mcp": true }`。

### 6.4 `xiaozhi_service.dart`（**核心新增**）
- `_handleTextMessage()` 新增 `case 'mcp':` 分支，按第四节实现 4 种响应。
- 提取一个 `_handleMcpMessage(jsonData)` 方法，负责构造并回送 MCP 响应。

### 6.5 UI（`settings_screen.dart` / `xiaozhi_config_selector_screen.dart`）
- 「小智服务」列表的「添加服务」里多一个选项 **「自建 Worker」**，无需填 URL（已写死）。

### 6.6 切换服务
- 切换时调用 `XiaozhiService.resetInstance()`，避免复用旧 configType。

---

## 七、验证清单

- [ ] OTA 请求带上 `dm` + `Accept-Language`，返回含 `websocket.url` 和 `token`
- [ ] WebSocket URL query 含 `authorization/device-id/client-id/dm/lang`
- [ ] hello 含 `features.mcp: true`
- [ ] 收到 `initialize` 能正确回 `protocolVersion/capabilities/serverInfo`
- [ ] 收到 `tools/list` 回空 tools
- [ ] 收到 `tools/call` 回 `-32601` 错误
- [ ] 所有 MCP 响应原样回传 `session_id` 和 `payload.id`
- [ ] 连接后能正常 stt/tts/llm 通信，不卡死
