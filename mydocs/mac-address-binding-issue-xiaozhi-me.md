# 更换 MAC 地址后 "没有找到该设备的版本信息" 问题分析与修复方案

## 一、问题描述

Android 客户端连接官方 xiaozhi.me（`wss://api.tenclass.net/xiaozhi/v1/`），更换 MAC 地址后：
- 官方 WebUI：能正常收到六位数绑定码，可以重新绑定设备
- Android 客户端：报错 "没有找到该设备的版本信息，请正确配置OTA地址"

## 二、根因分析

### 官方 WebUI 的正确流程

**配置来源（config.json）：**
```json
{
    "WS_URL": "wss://api.tenclass.net/xiaozhi/v1/",
    "OTA_VERSION_URL": "https://api.tenclass.net/xiaozhi/ota/",
    "DEVICE_ID": "00:15:5d:5d:f6:d6",
    "CLIENT_ID": "c3428233-d0c3-4ab9-870d-6ce07f278b35",
    "TOKEN": "test_token"
}
```

**注意：WS_URL 和 OTA_VERSION_URL 都是从 config.json hardcode 获取的。**

```python
# websocket_proxy.py 构造函数
def __init__(self, ...):
    self.device_id = device_id    # MAC 地址（config.json 的 DEVICE_ID）
    self.client_id = client_id    # UUID（config.json 的 CLIENT_ID）
    self.websocket_url = websocket_url   # config.json 的 WS_URL（hardcode）
    self.ota_version_url = ota_version_url  # config.json 的 OTA_VERSION_URL（hardcode）

    self.headers = {
        "Device-Id": self.device_id,       # MAC
        "Client-Id": self.client_id,       # UUID
        "Protocol-Version": "1",
    }
    self.headers["Authorization"] = f"Bearer {self.token}"

    self._update_ota_address()  # ← 关键！初始化时就调 OTA 注册设备
```

```python
# _update_ota_address() 做了：
# 1. POST OTA 接口，在服务端注册/识别设备
# 2. 获取认证 Token（用于 WebSocket 的 Authorization header）
# 注意：WS_URL 不从 OTA 获取！WS_URL 是 hardcode 的！
```

```
WebUI 完整流程:
  1. 读取 config.json → 获取 hardcode 的 WS_URL 和 OTA_VERSION_URL
  2. 调用 OTA（POST api.tenclass.net/xiaozhi/ota/）
     → 服务端在数据库中创建/更新设备记录（MAC + UUID）
     → 返回 websocket.token（用于认证）
  3. 用 hardcode 的 WS_URL + headers 连接 WebSocket
     headers: Device-Id=MAC, Client-Id=UUID, Authorization=Bearer <token>
  4. 发送 hello（version: 3）
  5. 服务端根据 MAC + UUID 查到设备记录 → 返回六位数绑定码
```

### Android 客户端的问题流程（修复前）

```
Android 客户端完整流程（有 bug）:
  1. 用户手动填 WebSocket URL，直接连接
  2. 没有调 OTA！服务端数据库里没有这个设备的记录
  3. 用 headers 连接 WebSocket
     → client-id 传的是 MAC 地址（应该是 UUID）
  4. 发送 hello（version: 1，多了 transport 字段）
  5. 服务端找不到设备 → 报错
```

## 三、Android 客户端的具体差异点

### 差异 1：缺少 OTA 调用（最关键）

**OTA 的作用不只是获取 URL，更是在服务端注册/识别设备。**

| | 官方 WebUI | Android 客户端（修复前） |
|--|-----------|----------------------|
| **WS_URL** | config.json hardcode | 用户手动填 |
| **OTA_URL** | config.json hardcode | 无 |
| **启动时** | 调用 OTA 接口注册设备 | 跳过，直接连接 |
| **服务端效果** | 设备已注册，能识别 | 设备未注册，找不到 |

### 差异 2：client-id 传了 MAC 而不是 UUID

```dart
// Android 客户端（修复前）— 错误
headers = {
    'device-id': '52:45:c6:a0:f1:d8',   // MAC
    'client-id': '52:45:c6:a0:f1:d8',   // MAC ← 重复了！
};

// 官方 WebUI — 正确
headers = {
    "Device-Id": "52:45:c6:a0:f1:d8",   // MAC
    "Client-Id": "4904b5d9-...",         // UUID
};
```

服务端用 `device-id(MAC)` + `client-id(UUID)` 组合来唯一标识设备。

### 差异 3：hello 消息 version 不一致

```json
// 官方 WebUI
{ "type": "hello", "version": 3, "audio_params": {...} }

// Android 客户端（修复前）
{ "type": "hello", "version": 1, "transport": "websocket", "audio_params": {...} }
```

### 差异 4：认证方式不一致

```python
# 官方 WebUI — 用 headers 认证
websockets.connect(ws_url, additional_headers={
    "Device-Id": device_id,
    "Client-Id": client_id,
    "Protocol-Version": "1",
    "Authorization": "Bearer {token}",
})
```

```dart
// Android 客户端（修复前）— 用 query params 认证
IOWebSocketChannel.connect(Uri.parse(url + "?authorization=Bearer+token&device-id=mac&client-id=uuid"))
```

## 四、修复方案

### 修复原则

**保持和官方 WebUI 完全一致的流程逻辑。**

### 修复内容

#### 1. WS_URL 和 OTA_URL 都 hardcode（与 WebUI config.json 一致）

```dart
// config_provider.dart
static const String OFFICIAL_WS_URL = 'wss://api.tenclass.net/xiaozhi/v1/';
static const String OFFICIAL_OTA_URL = 'https://api.tenclass.net/xiaozhi/ota/';
```

官方模式不再让用户填任何 URL。`addXiaozhiConfig()` 中：
- `websocketUrl = OFFICIAL_WS_URL`（hardcode）
- `otaUrl = OFFICIAL_OTA_URL`（hardcode）

#### 2. 统一 OTA 流程（OTA 只用于注册设备 + 获取 Token）

与 WebUI `_update_ota_address()` 一致：
- 调用 OTA POST 请求注册设备（发送完整 ESP32 设备信息）
- 从响应中提取 `websocket.token`
- **不从 OTA 获取 WS_URL**（WS_URL 是 hardcode 的）

#### 3. WebSocket 连接使用 headers 认证（与 WebUI 一致）

```dart
// 修复后（与 WebUI additional_headers 完全一致）
_channel = IOWebSocketChannel.connect(
  Uri.parse(wsUrl),
  headers: {
    'Device-Id': deviceId,
    'Client-Id': clientId,
    'Protocol-Version': '1',
    'Authorization': 'Bearer $token',
  },
);
```

#### 4. client-id 使用 UUID

`addXiaozhiConfig()` 和 `addCustomXiaozhiConfig()` 都生成并存储 UUID 作为 `clientId`。

#### 5. hello 消息对齐

```json
{
    "type": "hello",
    "version": 3,
    "audio_params": {
        "format": "opus",
        "sample_rate": 16000,
        "channels": 1,
        "frame_duration": 60
    }
}
```

## 五、已修改的文件清单

### 文件 1：`lib/providers/config_provider.dart`

- 新增 `OFFICIAL_WS_URL` 和 `OFFICIAL_OTA_URL` 两个 hardcode 常量
- `addXiaozhiConfig()`: 自动生成 UUID clientId，设置 hardcode 的 wsUrl 和 otaUrl

### 文件 2：`lib/services/xiaozhi_websocket_manager.dart`

- 构造函数新增 `wsUrl` 参数
- `_fetchOtaToken()` 重命名为 `_registerDevice()`，只提取 token（不获取 wsUrl）
- 删除 `_buildWebSocketUrl()`（不再需要拼接 query params）
- `connect()` 流程：调 OTA 注册 → 用 hardcode wsUrl + headers 连接 WebSocket

### 文件 3：`lib/services/xiaozhi_service.dart`

- 新增 `wsUrl` 字段和构造参数
- 所有创建 `XiaozhiWebSocketManager` 的地方传入 `wsUrl`

### 文件 4：`lib/screens/settings_screen.dart`

- `_showAddXiaozhiConfigDialog()`: 移除 WebSocket URL 和 Token 输入框
- `_showEditXiaozhiConfigDialog()`: 同上
- 配置列表显示 OTA 地址替代 Token

### 文件 5：`lib/screens/chat_screen.dart`

- `XiaozhiService()` 适配新参数：`macAddress`、`otaUrl`、`clientId`、`wsUrl`

### 文件 6：`lib/screens/voice_call_screen.dart`

- 同文件 5

## 六、UI 表单对比

### 修改前

```
┌─────────────────────────────────┐
│       添加小智服务              │
│                                 │
│  服务名称:  [____________]       │
│  WebSocket: [____________]       │  ← 不需要了
│  MAC地址:   [____________]       │
│  Token:     [____________]       │  ← 不需要了
│                                 │
│         [添加]  [取消]          │
└─────────────────────────────────┘
```

### 修改后

```
┌─────────────────────────────────┐
│       添加官方小智服务          │
│                                 │
│  服务名称:  [____________]       │
│  MAC地址:   [____________]       │  ← 留空自动生成
│             （留空自动生成）      │
│                                 │
│  连接信息将自动通过 OTA 获取    │
│                                 │
│         [添加]  [取消]          │
└─────────────────────────────────┘

┌─────────────────────────────────┐
│       添加自定义 Server          │
│                                 │
│  服务名称:  [____________]       │
│  OTA 地址:  [____________]       │
│             （OTA 接口会自动     │
│              返回连接信息）       │
│                                 │
│         [添加]  [取消]          │
└─────────────────────────────────┘
```

## 七、修改后的完整流程（与 WebUI 完全一致）

```
用户选择"官方 xiaozhi.me"
    │
    ▼
客户端从 hardcode 常量获取：
  WS_URL = wss://api.tenclass.net/xiaozhi/v1/
  OTA_VERSION_URL = https://api.tenclass.net/xiaozhi/ota/
自动生成 MAC 地址 + UUID
    │
    ▼
调用 OTA 接口注册设备（POST OTA_VERSION_URL）
  Headers: Device-Id=MAC
  Body: 完整 ESP32 设备信息（与 WebUI payload 一致）
    │
    ▼ 服务端注册/识别设备（MAC + UUID 组合标识）
    ▼ 返回 websocket.token
    │
    ▼
用 hardcode 的 WS_URL 连接 WebSocket
  Headers（与 WebUI additional_headers 一致）:
    Device-Id=MAC
    Client-Id=UUID
    Protocol-Version=1
    Authorization=Bearer <token>
    │
    ▼
发送 hello（version: 3, 与 WebUI WebSocketManager.ts 一致）
    │
    ├── 设备已绑定 → 正常对话
    ├── 设备未绑定 → 收到六位数绑定码（用户去 xiaozhi.me 完成绑定）
    └── 设备未注册 → 不应出现（OTA 已注册）
```

## 八、与官方 WebUI 的对照表

| 项目 | 官方 WebUI (websocket_proxy.py) | Android 客户端（修复后） |
|------|-------------------------------|----------------------|
| **WS_URL** | config.json hardcode: `wss://api.tenclass.net/xiaozhi/v1/` | Dart const hardcode: `OFFICIAL_WS_URL` |
| **OTA_URL** | config.json hardcode: `https://api.tenclass.net/xiaozhi/ota/` | Dart const hardcode: `OFFICIAL_OTA_URL` |
| **Device-Id** | config.json 的 `DEVICE_ID`（MAC 地址） | `XiaozhiConfig.macAddress` |
| **Client-Id** | config.json 的 `CLIENT_ID`（UUID） | `XiaozhiConfig.clientId`（UUID） |
| **认证方式** | WebSocket headers (`additional_headers`) | WebSocket headers (`headers` 参数) |
| **认证 header** | `Device-Id`, `Client-Id`, `Protocol-Version`, `Authorization` | 完全一致 |
| **OTA 调用时机** | 构造函数中自动调用 (`__init__`) | `connect()` 时自动调用 |
| **OTA payload** | 完整 ESP32 设备信息 | 完整 ESP32 设备信息（与 WebUI 一致） |
| **hello version** | 3 | 3 |
| **hello audio_params** | opus, 16000, 1ch, 60ms | opus, 16000, 1ch, 60ms |

## 九、调试过程中遇到的问题及解决

### 问题 1：旧配置兼容性 — OTA URL 和 Client-Id 为空

**现象：**
```
[connect-xiaozhi] OTA URL:
[connect-xiaozhi] Client-Id:
[connect-xiaozhi] ✗ OTA 注册异常: Invalid argument(s): No host specified in URI
```

**原因：** 用户在代码修改前创建的旧配置保存在 SharedPreferences 中，那时还没有 `otaUrl` 和 `clientId` 字段，值都是空字符串。

**解决：** 在 `chat_screen.dart` 和 `voice_call_screen.dart` 创建 `XiaozhiService` 时，对空值做兜底处理：
```dart
otaUrl: xiaozhiConfig.otaUrl?.isNotEmpty == true
    ? xiaozhiConfig.otaUrl!
    : ConfigProvider.OFFICIAL_OTA_URL,
clientId: xiaozhiConfig.clientId?.isNotEmpty == true
    ? xiaozhiConfig.clientId!
    : const Uuid().v4(),
wsUrl: xiaozhiConfig.websocketUrl?.isNotEmpty == true
    ? xiaozhiConfig.websocketUrl!
    : ConfigProvider.OFFICIAL_WS_URL,
```

**教训：** 新增字段时要考虑旧数据的兼容性，创建 service 时必须做 null/empty 兜底。

### 问题 2：WS_URL 不应该从 OTA 动态获取

**现象：** 初版修复中，`_fetchOtaToken()` 从 OTA 响应中提取 `websocket.url` 作为 WebSocket 连接地址。

**原因：** 官方 WebUI 的 `_update_ota_address()` 虽然也调 OTA，但 WS_URL 是从 config.json hardcode 的，不从 OTA 获取。OTA 的作用只是注册设备和获取 Token。

**解决：**
1. 新增 `OFFICIAL_WS_URL` 常量
2. `_registerDevice()` 方法只提取 token，不再提取 wsUrl
3. 删除 `_buildWebSocketUrl()` 方法
4. `connect()` 直接用传入的 hardcode wsUrl

### 问题 3：认证方式从 query params 改为 headers

**现象：** 初版修复中，认证信息通过 URL query params 传递：
```dart
IOWebSocketChannel.connect(Uri.parse(url + "?authorization=Bearer+token&device-id=mac&client-id=uuid"))
```

**原因：** 官方 WebUI 用 `additional_headers` 传递认证信息，不是 query params。

**解决：** 改用 `IOWebSocketChannel.connect()` 的 `headers` 参数：
```dart
_channel = IOWebSocketChannel.connect(
  Uri.parse(wsUrl),
  headers: {
    'Device-Id': deviceId,
    'Client-Id': clientId,
    'Protocol-Version': '1',
    'Authorization': 'Bearer $token',
  },
);
```

### 问题 4：Flutter null 安全编译错误

**现象：**
```
lib/screens/settings_screen.dart:1993:39: Error: Property 'isNotEmpty' cannot be accessed on 'String?' because it is potentially null.
```

**原因：** `XiaozhiConfig.otaUrl`、`clientId` 等字段声明为 `String?`，但使用时没有做空安全处理。

**解决：** 在所有使用处加 `?? ''` 或 `?.isNotEmpty == true` 空安全检查。

### 问题 5：OTA payload 字段不完整

**现象：** 早期版本的 OTA 请求 body 只发送了简单的 `device_id` + `device_name`，服务端返回"没有找到该设备的版本信息"。

**原因：** 官方 WebUI 的 OTA payload 包含完整的 ESP32 设备信息（flash_size、chip_model_name、chip_info、application 等），服务端需要这些信息来识别设备类型。

**解决：** 对齐 WebUI 的 payload 格式，添加了完整的 ESP32 设备信息字段。

## 十、调试方法

### 查看连接日志

使用自定义 tag `connect-xiaozhi` 过滤日志：
```bash
adb -s <device>:<port> logcat -s flutter | grep connect-xiaozhi
```

日志会输出完整的连接流程：
1. `WebSocketManager 创建` — 参数是否正确传入
2. `【步骤1】开始 OTA 注册设备` — OTA URL、Device-Id、Client-Id
3. `OTA HTTP 状态码` 和 `OTA 响应 body` — 服务端返回内容
4. `【步骤2】开始连接 WebSocket` — 目标 URL 和 Headers
5. `【步骤3】发送 hello 消息` — hello 内容
6. `← 收到文本消息` — 服务端响应
7. `✗` 开头 — 失败信息

### 清除 App 数据（重新测试）

```bash
adb -s <device>:<port> shell pm clear <package_name>
```
