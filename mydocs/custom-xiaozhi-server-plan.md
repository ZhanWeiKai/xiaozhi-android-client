# Android 客户端新增自定义 xiaozhi-server 连接方式

## 一、背景

当前 Android 客户端连接小智服务的方式：
- 用户手动填写：服务名称、WebSocket URL、MAC 地址、Token
- 连接时通过 **HTTP headers** 传递 `device-id`、`client-id`、`Authorization`
- 适配的是**官方 xiaozhi.me**

自定义 xiaozhi-server 的连接方式：
- 用户只需填写一个 **OTA URL**
- 客户端调用 OTA 接口，自动获取 WebSocket URL、Token、Client ID
- 连接时通过 **URL query params** 传递认证信息

本次改动：**保留现有官方连接方式，新增自定义 server 连接方式**。

---

## 二、两种连接方式对比

### 方式 A：官方 xiaozhi.me（现有流程，保留不变）

```
用户填写: 名称、WS URL、MAC 地址、Token
    │
    ▼
连接 WebSocket (headers 传递认证)
    │
    ▼
发送 hello 消息 → 开始对话
```

### 方式 B：自定义 xiaozhi-server（新增）

```
用户填写: 名称、OTA URL（如 https://xiaozhi-wstest.jamesweb.org/xiaozhi/ota/）
    │
    ▼
客户端自动生成 DEVICE_ID（MAC）、CLIENT_ID（UUID）
    │
    ▼
POST OTA 接口
  Headers: Device-Id=<MAC>, Client-Id=<UUID>
  Body: 设备信息 JSON
    │
    ▼
OTA 返回: { "websocket": { "url": "wss://...", "token": "OTA_TOKEN" } }
    │
    ▼
拼接 WebSocket URL (query params 传递认证):
  wss://.../xiaozhi/v1?authorization=Bearer <OTA_TOKEN>&device-id=<MAC>&client-id=<UUID>
    │
    ▼
发送 hello 消息 → 开始对话
```

---

## 三、UI 交互改动

### 改动位置

`lib/screens/settings_screen.dart` 中的 `_showAddXiaozhiConfigDialog()` 方法

### 现有流程

```
点击"添加服务" → 直接弹出填写表单（名称、WS URL、MAC、Token）
```

### 改为

```
点击"添加服务" → 弹出选择窗口
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
  自定义 Server            官方 xiaozhi.me
  [选择此方式]             [选择此方式]
        │                       │
        ▼                       ▼
  填写: 服务名称            填写: 服务名称
  填写: OTA URL             填写: WebSocket URL
  (其他全自动)              填写: MAC 地址
                             填写: Token
```

### 编辑配置时

编辑时根据配置类型（`configType` 字段）决定显示哪个表单：
- `official` → 显示现有表单（WS URL、MAC、Token）
- `custom` → 显示自定义表单（OTA URL，其他只读展示）

---

## 四、数据模型改动

### 修改文件：`lib/models/xiaozhi_config.dart`

新增字段 `configType`（区分连接方式）和 `otaUrl`、`clientId`：

```dart
class XiaozhiConfig {
  final String id;
  final String name;
  final String websocketUrl;
  final String macAddress;
  final String token;
  final String configType;   // 【新增】"official" 或 "custom"
  final String? otaUrl;      // 【新增】自定义 server 的 OTA 地址
  final String? clientId;    // 【新增】自定义 server 的 CLIENT_ID (UUID)
  // ...
}
```

- `configType == "official"`：现有流程，字段含义不变
- `configType == "custom"`：OTA 流程
  - `otaUrl`：用户填写的 OTA 地址
  - `websocketUrl`：从 OTA 返回自动获取
  - `token`：从 OTA 返回自动获取
  - `macAddress`：客户端自动生成（MAC 格式）
  - `clientId`：客户端自动生成（UUID 格式）

### 向后兼容

旧配置没有 `configType` 字段，`fromJson` 中默认为 `"official"`，不影响已有用户数据。

---

## 五、需要改动的文件清单

### 1. `lib/models/xiaozhi_config.dart` — 【修改】

**改动内容：**
- 新增 `configType` 字段（String，默认 `"official"`）
- 新增 `otaUrl` 字段（String?，可选）
- 新增 `clientId` 字段（String?，可选）
- `fromJson`：读取新字段，`configType` 缺省为 `"official"`
- `toJson`：序列化新字段
- `copyWith`：支持新字段的拷贝

---

### 2. `lib/providers/config_provider.dart` — 【修改】

**改动内容：**
- `addXiaozhiConfig()` 方法签名不变，但增加可选参数 `configType`、`otaUrl`
- 新增 `addCustomXiaozhiConfig(String name, String otaUrl)` 方法
  - 自动生成 `macAddress`（MAC 格式）
  - 自动生成 `clientId`（UUID 格式）
  - `configType` 设为 `"custom"`
  - `websocketUrl` 和 `token` 初始为空字符串（后续连接时通过 OTA 填充）

---

### 3. `lib/services/xiaozhi_websocket_manager.dart` — 【修改】

**改动内容：**

#### 3.1 `connect()` 方法
- 新增 `configType` 参数
- 当 `configType == "custom"` 时：
  - 先调用 `_fetchOtaToken()` 获取 WebSocket URL 和 Token
  - 然后用 URL params 方式连接（不传 headers）
- 当 `configType == "official"` 时：
  - 保持现有逻辑不变（HTTP headers 方式）

#### 3.2 新增 `_fetchOtaToken()` 方法
```
输入: otaUrl, deviceId(MAC), clientId(UUID)
流程:
  1. POST $otaUrl
     Headers: { "Device-Id": deviceId, "Client-Id": clientId, "Content-Type": "application/json" }
     Body: { "device_id": deviceId, "device_name": "Android客户端" }
  2. 解析返回 JSON:
     websocket.url → wsUrl
     websocket.token → token
  3. 返回 (wsUrl, token)
```

#### 3.3 新增 `_buildWebSocketUrl()` 方法
```
输入: baseUrl, token, deviceId, clientId
输出: baseUrl?authorization=Bearer <token>&device-id=<deviceId>&client-id=<clientId>
```

#### 3.4 修改连接逻辑
当 `configType == "custom"` 时：
```dart
// 不再传 headers，改为拼 URL params
final wsUrl = _buildWebSocketUrl(wsBaseUrl, token, deviceId, clientId);
_channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
```

---

### 4. `lib/services/xiaozhi_service.dart` — 【修改】

**改动内容：**

#### 4.1 `XiaozhiService` 类
- 新增 `configType` 字段（String）
- 新增 `otaUrl` 字段（String?）
- 新增 `clientId` 字段（String?）
- 工厂构造函数和内部构造函数增加对应参数

#### 4.2 `connect()` 方法
- 将 `configType` 传递给 `_webSocketManager.connect()`

---

### 5. `lib/screens/settings_screen.dart` — 【修改】

**改动内容：**

#### 5.1 新增 `_showAddServiceTypeDialog()` 方法
弹出选择窗口，两个选项卡片：
- "自定义 xiaozhi-server"：描述 + 图标，点击后调用 `_showAddCustomXiaozhiConfigDialog()`
- "官方 xiaozhi.me"：描述 + 图标，点击后调用现有的 `_showAddXiaozhiConfigDialog()`

#### 5.2 新增 `_showAddCustomXiaozhiConfigDialog()` 方法
配置表单，只需填写：
- 服务名称（必填）
- OTA URL（必填，带 hint 提示格式）
- 其他说明文字："连接时会自动获取 WebSocket 地址和认证信息"

#### 5.3 修改"添加服务"按钮
原来直接调用 `_showAddXiaozhiConfigDialog()`，改为调用 `_showAddServiceTypeDialog()`

#### 5.4 修改 `_showEditXiaozhiConfigDialog()` 方法
根据 `config.configType`：
- `"custom"` → 显示自定义编辑表单（OTA URL 可修改，WS URL/Token 只读展示）
- `"official"` → 显示现有编辑表单

#### 5.5 配置列表项显示
- 自定义类型：显示 OTA URL
- 官方类型：显示 WebSocket URL

---

### 6. `lib/screens/chat_screen.dart` — 【修改】

**改动内容：**
- 创建 `XiaozhiService` 时传入 `configType`、`otaUrl`、`clientId` 参数

---

### 7. `lib/screens/voice_call_screen.dart` — 【修改】

**改动内容：**
- 创建 `XiaozhiService` 时传入 `configType`、`otaUrl`、`clientId` 参数

---

## 六、自定义 server 连接完整流程图

```
用户操作:
  1. 设置页面 → 小智服务 Tab → 点击"添加服务"
  2. 弹出选择窗口 → 点击"自定义 xiaozhi-server"
  3. 填写: 名称="我的小智", OTA URL="https://xiaozhi-wstest.jamesweb.org/xiaozhi/ota/"
  4. 点击"添加"

客户端处理:
  5. addCustomXiaozhiConfig(name, otaUrl)
     - 自动生成 macAddress (MAC格式)
     - 自动生成 clientId (UUID格式)
     - configType = "custom"
     - 保存到 SharedPreferences

连接时:
  6. 用户选择该服务 → 进入聊天
  7. XiaozhiService.connect()
     → WebSocketManager.connect(url, token, configType: "custom", otaUrl, clientId, deviceId)

  8. WebSocketManager 检测 configType == "custom":
     8.1 _fetchOtaToken(otaUrl, deviceId, clientId)
         → POST OTA
         → 返回 (wsUrl, otaToken)
     8.2 _buildWebSocketUrl(wsUrl, otaToken, deviceId, clientId)
         → wss://...?authorization=Bearer <token>&device-id=<MAC>&client-id=<UUID>
     8.3 IOWebSocketChannel.connect(拼接后的URL)  ← 不传 headers
     8.4 发送 hello 消息（与现有流程一致）

  9. 连接成功 → 开始对话
```

---

## 七、注意事项

1. **OTA Token 有效期**：服务端 token 有效期 30 天，连接时如果 token 过期需要重新调用 OTA 获取
2. **断线重连**：自定义 server 重连时需要重新调 OTA 获取新 token
3. **内网地址替换**：OTA 返回的 URL 可能是内网地址（如 `ws://10.88.1.x:8000`），客户端需要判断是否可达，不可达时替换为外网地址
4. **向后兼容**：旧的 `configType` 为 `"official"` 的配置完全不受影响
5. **OTA 请求 body**：参考 xiaozhi-test 的实现，body 传设备信息即可，具体字段待 OTA 接口联调确认
