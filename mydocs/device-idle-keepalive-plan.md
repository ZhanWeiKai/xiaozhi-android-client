# 设备 Idle 态保持 Worker 连接 — 实现方案

> 日期：2026-07-31
> 分类：plan
> 状态：待实施
> 关联：`ota-upgrade-flow.md`（worker OTA）、`device-mcp-booking-implementation-plan.md`、`device-mcp-photo-vision-implementation-plan.md`

## 1. 背景

真实使用场景是 ESP32 xiaozhi device。ESP32 有状态机：`Starting → Activating(OTA) → Idle → Connecting → Listening → Speaking → Idle`（`xiaozhi-esp32/main/application.cc`）。

- **Idle**：`OpenAudioChannel()`（连 WS+开音频）只在 wake word/按钮触发时调；对话结束/网络断 → `CloseAudioChannel()` 回 Idle。**Idle 时 WS 是断的**。
- 唤醒词/按钮 → `Connecting` → `OpenAudioChannel()` 连 WS → `Listening`。

**问题**：worker 要在 Idle 也能给设备推 `tools/call`（远程拍照等）让设备干活。但 ESP32 Idle 时 WS 断开，worker 没通道。所以要让 **Idle 也保持和 worker 的 WS 长连接**（即使上游 tenclass 断开），唤醒才连上游。

先在 **Android** 模拟这套（ESP32 是真实目标，同模型，固件另做）。

## 2. 关键发现：worker 本就支持"长 WS + 按需连上游"

worker `proxy.js:295-330` 已实现"长 WS 生命周期"：
- accept 设备 WS 立即返回 101，设备 idle 持有 WS + 30s 心跳 + 10s KV 轮询。
- 上游 tenclass **不预连**；设备发 `hello`（唤醒）才 `resolveIdentity → fetch upstream → 转发 hello → 接双向管道`（386-444）。

**唯一违背需求处**：`proxy.js:452-459` `forceReconnect`——上游一断就 `workerSocket.close()` 把设备 WS 也关了，逼设备重连（这就是 Android 看到的"断几秒又自动重连"blip）。

所以 worker 侧改动很小；Android 侧要实现 Idle/Listening 状态机（不再连上就 hello）。

## 3. 设计目标

1. 设备 WS 到 worker **一直保持**（Idle 不断、上游断不断、对话结束不断）。
2. 上游 tenclass **按需连**：唤醒（Android 的通话按钮）→ hello → worker 连上游 → Listening；对话结束/上游断 → 回 Idle（不关 worker WS）。
3. Idle 时 worker 仍能推 `tools/call`（远程拍照等），设备照常执行回结果。
4. AppBar 状态区分"已连 worker(Idle)"与"对话中(Listening)"。
5. 可接受上游断后上下文丢失（透明重连上游 = 新 session），但不能接受设备 WS blip。

## 4. Worker 侧改动（`xiaozhi-dev-2/src/lib/proxy.js`）

### 4.1 上游断开 → 设备回 Idle，不关设备 WS

把 `forceReconnect`（452-459）从"关设备 WS"改成"拆上游管道 + 回 idle"：

```js
const onUpstreamClosed = () => {
  if (reconnecting) return;            // 重入保护
  reconnecting = true;
  // 1. 拆旧上游管道：移除旧 upstreamSocket 的 message/close/error 监听，close 旧 socket
  // 2. upstreamConnected = false（下次设备 hello 能重新触发连上游）
  // 3. 不关 workerSocket；重启 idle 心跳(heartbeatTimer) + 保留 KV 轮询(cmdTimer)
  //    （forceReconnect 里 clearInterval(cmdTimer) 要去掉——idle 还要轮询推命令）
  // 4. （可选）给设备发一帧通知"回 idle 了"（见 4.3）
  reconnecting = false;
};
upstreamSocket.addEventListener('close', onUpstreamClosed);
upstreamSocket.addEventListener('error', onUpstreamClosed);
```

设备 WS 全程不动，worker 回到 idle 态（心跳 + KV 轮询继续跑）。

### 4.2 Idle 也能推 tools/call（放开 sessionHolder.id gate）

现在 KV 轮询 gate 在 `if (cmd && sessionHolder.id)`（338）——idle 没发过 hello，`sessionHolder.id` 为 null，worker 推不了命令。改为：

- idle 推 `tools/call` 时用**合成/空 session_id**（`session_id: sessionHolder.id ?? null` 或合成一个），不再 gate。
- 设备侧 `_handleMcpMessage` 本就按 `payload.id` 响应（不依赖 session_id），能正常回。worker 的 MCP client 端按 `id` 收响应即可。

这样 worker 在设备 idle 也能远程拍照/调用 tool。

### 4.3 （待定）给设备发"回 idle"信号

上游断 worker 回 idle 后，要不要主动告诉设备？选项：
- **A. 不发**：设备靠自己状态机（见 §5）——离开通话页/无音频活动即 idle。
- **B. 发一帧** `{type:'tts', state:'stop'}`（复用现有协议，设备停 TTS 回 idle）或自定义 `{type:'session_closed'}`。

倾向 **B**（复用 `tts stop`），设备收到即回 idle。写实现时定。

## 5. Android 侧改动（模拟 ESP32 状态机）

### 5.1 不再连上就 hello

现在 `xiaozhi_websocket_manager.dart:285-286` 连上 200ms 自动 `_sendHelloMessage()` = 永远 Listening。改成：

- `connect()` 只连 WS（OTA → WS → 监听 → 派发 connected），**不发 hello**，进 Idle。
- 心跳（30s）继续保活 worker WS（已实现）。
- 加一个公开方法 `sendHello()`（把现有 `_sendHelloMessage` 暴露/重命名），供唤醒调用。

### 5.2 唤醒触发 = 通话按钮（方案 A）

chat 页 AppBar 的电话按钮（`chat_screen.dart:464 _navigateToVoiceCall`）现为"进入 VoiceCallScreen"。复用它当唤醒：

- 进 VoiceCallScreen → `connectVoiceCall()` 连 WS（若未连）+ **`sendHello()`** → worker 连上游 → Listening（现有 hello 回复触发自动录音的逻辑保留）。
- VoiceCallScreen 退出 → **不 `disconnectVoiceCall()` 关 WS**，改成"停录音 + 停 TTS + 回 Idle"（保留 worker WS）。上游由 worker 侧按 §4 处理（断开 → worker 回 idle）。

### 5.3 状态机 + AppBar

- `VoiceCallState` 已有 idle/userSpeaking/aiSpeaking（`xiaozhi_service.dart`）。在此基础上区分"WS 连接到 worker(Idle)" vs "上游已连(Listening)"。
- AppBar chip（已有固件 chip 那块）旁边加连接态：`已连接(Idle)` / `对话中(Listening)` / `未连接`。
- Idle 时 chat 页仍可收 worker 推的 `tools/call`（`_handleMcpMessage` 本就独立于上游，照常跑；拍照结果照常展示，见之前 photoCaptured 改动）。

### 5.4 上游断 → 回 Idle（不 blip）

worker §4.1 不关设备 WS 后，Android 收不到 disconnect 事件 → 不触发现有自动重连（manager 3s + chat 2s 轮询）→ 无 blip。worker 若发 §4.3 的"回 idle"信号，Android 收到即停 TTS/录音回 Idle 状态。Android 那套自动重连逻辑保留作真断网兜底（worker↔设备 WS 真断才触发）。

## 6. 数据流

### 6.1 Idle（常驻）

```
打开对话 → connect() 连 worker WS（不发 hello）→ Idle
  ├ 30s 心跳保活 worker WS
  ├ worker 10s KV 轮询；有命令 → 推 tools/call（合成 session_id）
  └ 设备执行 tool（拍照等）→ 回结果给 worker
AppBar: 已连接(Idle)
```

### 6.2 唤醒 → Listening

```
点通话按钮 → VoiceCallScreen → connectVoiceCall() + sendHello()
→ worker: hello → resolveIdentity → 连上游 → 转发 hello → 接管道
→ 上游 hello 回复 → 设备开始录音 → Listening
AppBar: 对话中(Listening)
```

### 6.3 上游断 → 回 Idle（不 blip）

```
上游 tenclass 断 → worker onUpstreamClosed:
  拆上游管道 + upstreamConnected=false + 重启 idle 心跳/轮询 + 不关设备 WS
  （可选）发 tts stop 给设备
→ 设备收 tts stop → 停 TTS/录音 → 回 Idle（worker WS 一直没断）
→ worker 仍能在 idle 推 tools/call
AppBar: 已连接(Idle)
```

## 7. ESP32（真实目标，后续）

ESP32 要同模型：Idle 时**不 `CloseAudioChannel()` 关 WS**（只停音频流），保留 worker WS；唤醒才 `OpenAudioChannel` 连上游。这是固件改动（`application.cc` 的 idle/close 逻辑），本 spec 不覆盖，单独立项。

## 8. 待确认

1. §4.3 上游断后 worker 要不要主动给设备发"回 idle"帧？倾向发 `tts stop`，写实现时定。
2. §5.2 VoiceCallScreen 退出时，除了停录音/TTS，要不要给 worker 发一帧"主动结束本轮"让上游早断？还是等上游自己 idle 超时？倾向后者（简单）。
3. §5.3 Idle 时 AppBar 是否还要保留"通话按钮"可点（=唤醒）？是。
4. KV 轮询在 idle 用合成 session_id 推 tools/call，worker MCP client 端要确认能按 `id` 收响应（不依赖 session_id 路由）。
5. Android 那套双重自动重连（manager 3s + chat 2s 轮询）在 idle 模型下基本不触发（WS 不断），是否顺手精简只留 manager 一套？倾向暂不动（避免回归），后续看日志。
