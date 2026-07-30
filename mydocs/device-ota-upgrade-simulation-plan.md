# Android 模拟 OTA 升级 — 实现方案

> 日期：2026-07-30
> 分类：plan
> 状态：待实施
> 关联：自建 Worker（`xiaozhi-dev-2`）的 OTA 下发逻辑，见 `ota-upgrade-flow.md`

## 1. 目标

在 Android app（xiaozhi-android-client）连上自建 Worker 后，像 `simulate.html` 那样模拟 OTA 升级：

1. **连接时 OTA 检查**：连 worker 时 POST `/xiaozhi/ota/`，解析 worker 下发的 `firmware.{version,url}`。**仅自建 Worker 连接（`configType=='worker'`）做此模拟**；official/custom 的 OTA 不注入 firmware，跳过。
2. **检测到新版自动下载**：worker 给了 `firmware.url` 就自动 fetch bin 到内存、报告字节数（不真烧录，Android 无 OTA 分区；**只存内存不落盘**），下载后把"设备上报版本"升到新版，下次 OTA 检查显示 up to date。
3. **聊天页常驻显示当前固件版本**：在 chat 页 AppBar 常驻一个版本 chip，下载中显示"→ vX 下载中…"。
4. **首次必升（-1 哨兵）**：fresh 设备（config 未存 firmware 版本）上报 `version:"-1"`；worker 是字符串不等比较，`目标版本 != "-1"` 恒成立 → 首次连必触发下载；下完 bump 成真实版本，下次匹配不再下。UI 上 "-1" 显示"未安装"。

## 2. 现状（Android 侧）

`lib/services/xiaozhi_websocket_manager.dart` 的 `_registerDevice()`：

- OTA body 里 `application.version` **写死 `'1.1.2'`**（不随设备状态变）。
- OTA 响应**只取** `websocket.token` / `websocket.url`，**不解析 `firmware` 字段**，worker 下发的升级信息被丢弃。
- 不下载固件。
- `lib/models/xiaozhi_config.dart` 没有"当前固件版本"字段。
- `lib/screens/chat_screen.dart` 的 AppBar 不显示固件版本。

参考实现：自建 Worker 项目的 `public/simulate.html` 的 `connectDevice()` + `simulateDownloadFirmware()`——OTA 解析、手动下载、bump `simVersion`。本方案把这套搬进 Android，并把"手动"改"自动"。

## 3. 要改哪里（文件级 + 具体位置）

### 3.1 `lib/models/xiaozhi_config.dart` — 加固件版本字段

加 `firmwareVersion`（设备当前"已安装"版本，**默认 `'-1'`**（未安装哨兵），持久化进 SharedPreferences（随 config 一起存），重启后保留、下次 OTA 上报该版本。

```dart
final String firmwareVersion;   // 新增，默认 '1.1.2'
// 构造、fromJson、toJson、copyWith 都带上
```

`fromJson` 缺省取 `'1.1.2'`（兼容旧配置）。

### 3.2 `lib/services/xiaozhi_websocket_manager.dart` — OTA 解析 + 自动下载

**(a) 事件类型**：`enum XiaozhiEventType` 加一项 `firmwareUpdate`。

**(b) 构造函数**：加 `String firmwareVersion = '1.1.2'` 参数（设备当前版本，用于 OTA body）。

**(c) `_registerDevice()`**：

- OTA body 的 `application.version` 用传入的 `firmwareVersion`（不再写死）。
- 解析响应里的 `firmware`：取 `firmware.version`、`firmware.url`。
- 返回 Map 增加 `firmwareVersion`（目标版本，可能 null）、`firmwareUrl`（下载地址，可能 null）。

```dart
final fw = data['firmware'];
String? fwVer = fw is Map ? fw['version']?.toString() : null;
String? fwUrl = fw is Map ? fw['url']?.toString() : null;
return {
  'token': token,
  if (otaWsUrl != null) 'wsUrl': otaWsUrl,
  if (fwVer != null) 'firmwareVersion': fwVer,
  if (fwUrl != null) 'firmwareUrl': fwUrl,
};
```

**(d) `connect()`**：OTA 后拿到 `firmwareUrl`，先继续 WS 连接（让聊天尽快可用），把 `firmwareUrl`/目标版本存到实例字段。WS `onopen`（或 OTA 后即起一个后台任务）触发自动下载。

**(e) 新增 `_autoDownloadFirmware(String url, String newVersion)`**：

```dart
Future<void> _autoDownloadFirmware(String url, String newVersion) async {
  _dispatchEvent(XiaozhiEvent(type: XiaozhiEventType.firmwareUpdate,
      data: {'state': 'downloading', 'from': _firmwareVersion, 'to': newVersion}));
  try {
    final resp = await (await HttpClient().getUrl(Uri.parse(url))).close();
    final bytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
    _dispatchEvent(XiaozhiEvent(type: XiaozhiEventType.firmwareUpdate,
        data: {'state': 'done', 'from': _firmwareVersion, 'to': newVersion,
               'bytes': bytes.length}));
  } catch (e) {
    _dispatchEvent(XiaozhiEvent(type: XiaozhiEventType.firmwareUpdate,
        data: {'state': 'error', 'error': e.toString(), 'to': newVersion}));
  }
}
```

下载成功 → 事件 `state:done`；上层（XiaozhiService）据此把 `firmwareVersion` bump 成 `newVersion` 并持久化。失败不 bump，UI 显示失败。

### 3.3 `lib/services/xiaozhi_service.dart` — 串起来

- 创建 manager 时（`_init` / `connect` / `connectVoiceCall` 三处）传入 `firmwareVersion`（取自当前 XiaozhiConfig 的 `firmwareVersion`）。
- `_onWebSocketEvent` 里处理 `XiaozhiEventType.firmwareUpdate`：
  - `state=downloading` → 派发 UI 事件"固件 vX 下载中"。
  - `state=done` → 调 `ConfigProvider` 把当前 config 的 `firmwareVersion` 改成 `newVersion` 并 `_saveConfigs()`（持久化），派发 UI 事件"固件已升级到 vX"。
  - `state=error` → 派发 UI 事件"固件下载失败"。
- 注意：xiaozhi_service 当前用 mac/otaUrl/clientId/wsUrl/configType/lang 等字段，需补一个"当前 config 的 firmwareVersion"来源（由启动语音/聊天时从 active XiaozhiConfig 注入）。

### 3.4 `lib/screens/chat_screen.dart` — 常驻版本显示

AppBar 的 `title: Row(...)`（xiaozhi 类型那条分支，~386 行）里，名字旁边加一个版本 chip：

- 平时：`固件 v1.1.2`（读当前 config 的 `firmwareVersion`）。
- 下载中：`固件 v1.1.2 → v2.0.6 下载中…`。
- 已升级：`固件 v2.0.6`。
- 失败：`固件 v1.1.2（下载失败）`。

数据来源：监听 XiaozhiService 的 firmwareUpdate 事件 + 读 ConfigProvider 当前 config 的 firmwareVersion。`setState` 刷新 chip。

## 4. 数据流

```text
连上 Worker（connect/connectVoiceCall）
→ XiaozhiWebSocketManager._registerDevice()
   POST /xiaozhi/ota/  body.application.version = config.firmwareVersion（如 1.1.2）
→ worker 比对 VERSIONS[dm] != 设备版本 → 注入 firmware{version,url}
→ 解析 firmwareVersion / firmwareUrl
→ 连 WebSocket（onopen）
→ _autoDownloadFirmware(url, newVersion)（后台）
   ├ 下载中 event → chat 页 chip 显示 "→ vX 下载中…"
   ├ 下载完成 event → XiaozhiService bump config.firmwareVersion = newVersion
   │   → ConfigProvider 持久化 → chat 页 chip 显示 "固件 vX"
   └ 失败 event → chip 显示 "（下载失败）"，不 bump
→ 下次连 worker 上报新版本 → worker 不再下发（版本相等）→ chip 只显示当前版本
```

## 5. 持久化

`firmwareVersion` 存 `XiaozhiConfig`（SharedPreferences），随 config 列表一起 `_saveConfigs()`。重启 app 后保留；下次 OTA 上报该版本，worker 判定"版本相等"不再下发，模拟"升级完成后 up to date"。

## 6. 错误处理

| 场景 | 行为 |
|---|---|
| OTA 响应无 `firmware` 字段 | 正常连 WS，chip 只显示当前版本 |
| `firmware.url` 下载失败 | 不 bump 版本，chip 显示"（下载失败）"，WS 不受影响 |
| 下载 bin 404（worker override 指向不存在的 bin） | 同上失败处理 |
| bump 版本后下次上报仍被下发（字符串不等会触发"降级"） | 按文档已知限制接受：worker 是字符串不等判断，可能下发更低版本；如出现可手动改 config.firmwareVersion |

## 7. 实施步骤

1. `XiaozhiConfig` 加 `firmwareVersion`（fromJson/toJson/copyWith，默认 1.1.2）。
2. `XiaozhiWebSocketManager`：加 `firmwareUpdate` 事件类型、构造参数 `firmwareVersion`、`_registerDevice` 解析 firmware、`_autoDownloadFirmware` 方法、connect 里触发。
3. `XiaozhiService`：创建 manager 传 firmwareVersion、`_onWebSocketEvent` 处理 firmwareUpdate、bump + 持久化、派发 UI 事件。
4. `chat_screen.dart`：AppBar 版本 chip + 监听事件刷新。
5. `flutter analyze` + build apk + 装机，连 worker 模式测一次（改 wrangler VERSIONS 触发下发，验证自动下载 + chip 更新）。

## 8. 待确认（已定）

1. ✅ 版本 chip 放 **AppBar**。
2. ✅ 下载 bin **只存内存**，不落盘。
3. ✅ **连接时查一次**，不加周期定时器。
4. ✅ fresh 设备用 **`-1` 哨兵**：未存版本时报 `-1`，worker 字符串不等必触发首次下载，下完 bump 真实版本。版本 **per-config**（每个 worker 配置一个"设备"各自升级）。
5. ✅ **仅 `configType=='worker'`** 做 OTA 模拟；official/custom 跳过。
