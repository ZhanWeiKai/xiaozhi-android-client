# Android 客户端自定义 xiaozhi-server 连接 — 实现文档

> 参考源码: `C:\claude-project\xiaozhi-webui\xiaozhi-webui-4-9\xiaozhi-webui\websocket_proxy.py`
> 参考文档: `C:\claude-project\xiaozhi-webui\xiaozhi-webui-4-9\xiaozhi-webui\docs\plans\xiaozhi-webui-summarize.md`

---

## 一、两种连接模式的区别

### 官方 xiaozhi.me (`configType == "official"`)

```
OTA 注册 (headers: Device-Id + Client-Id)
    │
    ▼
获取 Token (仅 token，不使用 wsUrl)
    │
    ▼
WebSocket 连接 (hardcoded WS_URL)
  认证方式: HTTP headers
    Device-Id: <MAC>
    Client-Id: <UUID>
    Protocol-Version: 1
    Authorization: Bearer <token>
    │
    ▼
发送 hello (简单格式，仅 version + audio_params)
```

### 自定义 xiaozhi-server (`configType == "custom"`)

```
OTA 注册 (headers: Device-Id + Client-Id)
    │
    ▼
获取 websocket.url + websocket.token
    │
    ▼
WebSocket 连接 (URL 从 OTA 获取)
  认证方式: URL query params
    wss://server/xiaozhi/v1?authorization=Bearer <OTA_TOKEN>&device-id=<MAC>&client-id=<UUID>
    │
    ▼
发送 hello (包含认证信息)
    device_id: <MAC>
    device_name: "xiaozhi-android"
    device_mac: <MAC>
    token: <OTA_TOKEN>
```

### 关键差异总结

| 项目 | 官方模式 | 自定义模式 |
|------|---------|-----------|
| WS_URL 来源 | 硬编码 (`wss://api.tenclass.net/xiaozhi/v1/`) | OTA 返回的 `websocket.url` |
| WebSocket 认证方式 | HTTP headers | URL query params |
| hello 消息 | 简单格式 (version + audio_params) | 包含 device_id, device_name, device_mac, token |
| Token 用途 | headers Authorization | query params + hello body |

---

## 二、认证机制详解（自定义 server）

自定义 xiaozhi-server 使用 HMAC-SHA256 签名的 Token 进行认证：

```
┌──────────────────────────────────────────────────────┐
│                  唯一 Token（OTA Token）               │
│                                                      │
│  生成方: xiaozhi-server OTA 接口 (ota_handler.py)     │
│  算法:   HMAC-SHA256(auth_key, "client_id|device_id|ts") │
│  传递:   URL query params → authorization=Bearer <token> │
│  校验:   websocket_server._handle_auth()              │
│  验证参数: verify_token(token, client_id, device_id)   │
│  有效期:  30 天                                        │
└──────────────────────────────────────────────────────┘
```

**注意**: xiaozhi-server 只通过 URL query params 中的 `authorization`、`device-id`、`client-id` 进行认证。
HTTP headers 中的认证信息对自定义 server **无效**。

---

## 三、代码实现

### 3.1 `xiaozhi_websocket_manager.dart` — 核心连接逻辑

新增 `configType` 参数区分两种模式：

```dart
class XiaozhiWebSocketManager {
  String _configType; // "official" 或 "custom"

  XiaozhiWebSocketManager({
    required String deviceId,
    required String otaUrl,
    required String clientId,
    required String wsUrl,
    String configType = 'official',  // 新增
  });
}
```

#### `_registerDevice()` — OTA 注册

与官方 WebUI 的 `_update_ota_address()` 保持一致：
- POST OTA URL
- Headers: `Device-Id`, `Client-Id`, `Content-Type`
- Body: 设备信息 JSON（与 WebUI 完全相同的 payload）
- 返回: `{ 'token': String, 'wsUrl'?: String }`
  - 官方模式: 只用 token
  - 自定义模式: 用 token + wsUrl

#### `connect()` — 双模式连接

```dart
Future<void> connect() async {
  // 1. OTA 注册
  final otaResult = await _registerDevice();

  if (_configType == 'custom') {
    // 自定义模式: WS_URL 从 OTA 获取，query params 认证
    _wsUrl = otaResult['wsUrl'];
    final fullUrl = _buildAuthUrl(_wsUrl, token, deviceId, clientId);
    _channel = IOWebSocketChannel.connect(Uri.parse(fullUrl));
  } else {
    // 官方模式: WS_URL 硬编码，headers 认证
    final headers = {
      'Device-Id': deviceId,
      'Client-Id': clientId,
      'Protocol-Version': '1',
      'Authorization': 'Bearer $token',
    };
    _channel = IOWebSocketChannel.connect(Uri.parse(_wsUrl), headers: headers);
  }

  // 发送 hello（两种模式内容不同）
  _sendHelloMessage();
}
```

#### `_buildAuthUrl()` — 构建 URL（新增）

与 WebUI 的 `_build_ws_url()` 一致：
```dart
String _buildAuthUrl(String baseUrl, String token, String deviceId, String clientId) {
  final separator = baseUrl.contains('?') ? '&' : '?';
  return '$baseUrl${separator}authorization=Bearer%20$token&device-id=$deviceId&client-id=$clientId';
}
```

#### `_sendHelloMessage()` — 双模式 hello

```dart
void _sendHelloMessage() {
  if (_configType == 'custom') {
    // 自定义 server: 包含认证信息（与 WebUI handle_client_messages 注入逻辑一致）
    hello = {
      "type": "hello",
      "version": 3,
      "audio_params": { ... },
      "device_id": _deviceId,
      "device_name": "xiaozhi-android",
      "device_mac": _deviceId,
      "token": _token,
    };
  } else {
    // 官方: 简单格式
    hello = {
      "type": "hello",
      "version": 3,
      "audio_params": { ... },
    };
  }
}
```

### 3.2 `xiaozhi_service.dart` — 传递 configType

```dart
class XiaozhiService {
  final String configType; // 新增字段

  factory XiaozhiService({
    required String macAddress,
    required String otaUrl,
    required String clientId,
    required String wsUrl,
    String configType = 'official',  // 新增参数
    String? sessionId,
  });
}
```

所有创建 `XiaozhiWebSocketManager` 的地方都传入 `configType`。

### 3.3 `chat_screen.dart` / `voice_call_screen.dart` — 传入 configType

```dart
_xiaozhiService = XiaozhiService(
  macAddress: xiaozhiConfig.macAddress,
  otaUrl: ...,
  clientId: ...,
  wsUrl: ...,
  configType: xiaozhiConfig.configType,  // 新增
);
```

---

## 四、数据流完整图示

### 自定义 Server 连接流程

```
用户操作:
  1. 设置页面 → 小智服务 → "添加服务" → "自定义 xiaozhi-server"
  2. 填写: 名称, OTA URL (如 https://xiaozhi.jamesweb.org/api/ota/)
  3. 点击"添加"

保存配置:
  4. addCustomXiaozhiConfig(name, otaUrl)
     - configType = "custom"
     - 自动生成 macAddress (MAC格式), clientId (UUID格式)
     - websocketUrl = "" (后续由 OTA 填充)
     - token = ""

连接流程:
  5. 用户选择该服务 → 进入聊天
  6. XiaozhiService(configType: "custom")
  7. WebSocketManager(configType: "custom").connect()

  8. _registerDevice()
     POST otaUrl
       Headers: Device-Id=<MAC>, Client-Id=<UUID>
       Body: { mac_address, uuid, chip_info, ... }
     ← 返回: { websocket: { url: "wss://...", token: "..." } }

  9. _buildAuthUrl()
     → wss://server/xiaozhi/v1?authorization=Bearer <token>&device-id=<MAC>&client-id=<UUID>

  10. IOWebSocketChannel.connect(fullUrl)  ← 无 headers

  11. _sendHelloMessage() (custom 格式)
      { type: "hello", device_id, device_name, device_mac, token, audio_params }

  12. 服务端 verify_token(token, client_id, device_id) → 认证通过
  13. 双向通信开始
```

---

## 五、注意事项

1. **OTA URL 格式**: 必须包含完整路径（含尾部斜杠），如 `https://xiaozhi.jamesweb.org/api/ota/`，否则可能返回 301
2. **内网地址**: OTA 返回的 URL 可能是内网地址（如 `ws://10.88.1.x:8000`），客户端需要判断可达性
3. **Token 有效期**: 自定义 server token 有效期 30 天，断线重连时需重新调 OTA
4. **向后兼容**: 旧配置无 `configType` 字段，`fromJson` 默认为 `"official"`，不影响已有用户
5. **单例重置**: 切换服务时必须调用 `XiaozhiService.resetInstance()` 避免复用旧配置

---

## 六、已完成的改动文件清单

| 文件 | 改动 |
|------|------|
| `lib/models/xiaozhi_config.dart` | 新增 `configType`, `otaUrl`, `clientId` 字段 |
| `lib/providers/config_provider.dart` | 新增 `addCustomXiaozhiConfig()`, 硬编码 URL 常量 |
| `lib/services/xiaozhi_websocket_manager.dart` | 双模式连接：configType 区分官方/自定义，_buildAuthUrl，双模式 hello |
| `lib/services/xiaozhi_service.dart` | 新增 configType 字段，传递到 WebSocketManager |
| `lib/screens/chat_screen.dart` | 创建服务时传入 configType |
| `lib/screens/voice_call_screen.dart` | 创建服务时传入 configType |
| `lib/screens/settings_screen.dart` | UI：添加官方/自定义选择，自定义只填 OTA URL |
