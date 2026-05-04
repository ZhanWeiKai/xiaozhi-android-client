# 小智语音通话协议分析与 Android 客户端修复方案

> 基于 WebUI (xiaozhi-webui-4-9) 源码分析，梳理完整的语音通话协议流程和 Android 客户端需要修改的代码。

---

## 一、WebUI 语音通话完整协议流程

### 1.1 整体架构

WebUI 使用 **状态机** 管理通话流程，核心组件：

| 组件 | 职责 |
|------|------|
| `WebSocketService` | WebSocket 连接管理，收发消息 |
| `ChatStateManager` | 三态状态机 (IDLE / USER_SPEAKING / AI_SPEAKING) |
| `AudioService` | 麦克风录音 + 音频电平检测 + 音频播放队列 |

### 1.2 连接建立流程

```
1. WebSocket 连接建立
2. 客户端发送 hello (含 audio_params)
3. 服务端回复 hello (含 session_id)
4. 客户端保存 session_id
5. 此时进入 IDLE 状态，等待用户说话
```

### 1.3 进入语音通话

```typescript
// App.vue - showVoiceCallPanel()
const showVoiceCallPanel = async () => {
  sendAbortMessage();              // 1. 发送 abort 消息（清理之前的会话）
  audioService.clearAudioQueue();  // 2. 清空音频播放队列
  isVoiceCallVisible.value = true; // 3. 显示通话面板
  await audioService.prepareMediaResources();  // 4. 初始化麦克风录音 → 开始持续采集音频
  if (chatStateManager.currentState.value != ChatState.IDLE) {
    chatStateManager.setState(ChatState.IDLE);  // 5. 重置为 IDLE 状态
  }
};
```

**关键点：`prepareMediaResources()` 之后，麦克风开始持续采集音频，并且每个音频 chunk 都会经过 `detectAudioLevel()` 计算电平，然后喂给 `chatStateManager.handleUserAudioLevel()`。麦克风在整个通话期间始终保持开启。**

### 1.4 音频数据流（核心）

```
麦克风 → getUserMedia → AudioWorklet (audioProcessor.js)
    → 每帧 Float32Array (16kHz, 960 samples = 60ms)
    → AudioManager.detectAudioLevel() 计算音频电平
    → audioService.onProcess(level, data) 回调
    → chatStateManager.handleUserAudioLevel(level, data)
    → 根据当前状态决定行为
```

**音频电平计算算法（AudioManager.ts）：**
```typescript
private detectAudioLevel = (audioData: Float32Array): number => {
    if (!audioData || !audioData.length) return 0;
    let sum = 0;
    for (let i = 0; i < audioData.length; i++) {
        sum += Math.abs(audioData[i]);
    }
    return sum / audioData.length;  // 平均绝对值，范围 0~1
}
```

**阈值配置（App.vue）：**
```typescript
thresholds: {
    USER_SPEAKING: 0.04,       // 用户开始说话的阈值
    USER_INTERRUPT_AI: 0.1,    // 用户打断 AI 的阈值（更高，避免误触发）
},
timeout: {
    SILENCE: 1000,             // 静音 1 秒后判定用户说完了
},
```

### 1.5 状态机详解（核心协议）

#### 三种状态

```
         音频电平 > 0.04              静音 1 秒后
IDLE ──────────────────────► USER_SPEAKING ──────────────────────► AI_SPEAKING
  ▲                                                            │
  │                        用户打断 (电平 > 0.1)                │
  └────────────────────────────────────────────────────────────┘
                            音频队列播放完毕
                              AI_SPEAKING ───► IDLE
```

#### IDLE 状态

- **行为**：等待用户说话，**麦克风仍在采集音频**
- **触发转换**：当 `audioLevel > 0.04` 时，进入 USER_SPEAKING

```typescript
// ChatStateManager.ts - IDLE 状态
this.transitions.set(ChatState.IDLE, {
    onEnter: () => { },  // 什么都不做
    handleAudioLevel: (audioLevel: number) => {
        if (audioLevel > this.deps.thresholds.USER_SPEAKING) {  // 0.04
            this.setState(ChatState.USER_SPEAKING);
        }
    }
})
```

#### USER_SPEAKING 状态

- **进入时**：
  1. 发送 `listen(state: start, mode: auto)` 到服务端
  2. 触发 `USER_START_SPEAKING` 事件 → **停止播放 + 清空音频队列**（防止残留 AI 音频干扰）
- **持续中**：
  1. **每一帧音频都发送到服务端**（不管电平高低）
  2. 检测静音：如果 `audioLevel < 0.04`，启动 1 秒静音计时器
  3. 如果 `audioLevel >= 0.04`（用户还在说话），取消静音计时器
- **退出时**：
  1. 发送 `listen(state: stop, mode: auto)` 到服务端
  2. 触发 `USER_STOP_SPEAKING` 事件

```typescript
// 进入 USER_SPEAKING 时
onEnter: (oldState) => {
    if (oldState === ChatState.USER_SPEAKING) return;  // 避免重复进入
    this.deps.callbacks.sendTextData(AIListening_Start);  // { type: "listen", state: "start", mode: "auto" }
    this.emit(ChatEvent.USER_START_SPEAKING);
},

// 退出 USER_SPEAKING 时
onExit: () => {
    if (this.silenceTimer) {
        clearTimeout(this.silenceTimer);
        this.silenceTimer = null;
    }
    this.deps.callbacks.sendTextData(AIListening_Stop);  // { type: "listen", state: "stop", mode: "auto" }
    this.emit(ChatEvent.USER_STOP_SPEAKING);
},

// USER_SPEAKING 中持续处理每一帧音频
handleAudioLevel: (audioLevel: number, data: Float32Array) => {
    this.deps.callbacks.sendAudioData(data);  // ← 不管电平高低，每一帧都发送到服务端！
    if (audioLevel < this.deps.thresholds.USER_SPEAKING) {  // < 0.04 静音
        if (!this.silenceTimer) {
            this.silenceTimer = setTimeout(() => {
                this.setState(ChatState.AI_SPEAKING);  // 静音1秒后 → AI_SPEAKING
            }, this.deps.timeout.SILENCE);  // 1000ms
        }
    } else {  // >= 0.04 还在说话
        if (this.silenceTimer) {
            clearTimeout(this.silenceTimer);  // 取消静音计时器
            this.silenceTimer = null;
        }
    }
},
```

**配套事件处理（App.vue）：**
```typescript
// 用户开始说话时 → 停止 AI 播放、清空残留音频
chatStateManager.on(ChatEvent.USER_START_SPEAKING, async () => {
    audioService.stopPlaying();
    audioService.clearAudioQueue();
});
```

#### AI_SPEAKING 状态

- **进入时**：触发 `AI_START_SPEAKING` 事件 → **开始播放音频队列**
- **持续中**：
  1. **麦克风仍在采集音频**（与 WebUI 的 AudioWorklet 一直运行有关）
  2. 检测用户打断：如果 `audioLevel > 0.1`，发送 abort → 回到 USER_SPEAKING
- **退出时**：触发 `AI_STOP_SPEAKING` 事件
- **播放完毕**：音频队列播放空后 → 回到 IDLE

```typescript
// AI_SPEAKING 进入时
onEnter: (oldState) => {
    if (oldState === ChatState.AI_SPEAKING) return;  // 避免重复进入
    this.emit(ChatEvent.AI_START_SPEAKING);
},

// AI_SPEAKING 中检测用户打断
handleAudioLevel: (audioLevel: number) => {
    if (audioLevel > this.deps.thresholds.USER_INTERRUPT_AI) {  // 0.1
        const abortMessage = AbortMessage(this.deps.callbacks.getSessionId());
        this.deps.callbacks.sendTextData(abortMessage);  // 发送 abort
        this.setState(ChatState.USER_SPEAKING);  // → 回到 USER_SPEAKING
    }
},
```

**配套事件处理（App.vue）：**
```typescript
// AI 开始说话时 → 开始播放音频队列
chatStateManager.on(ChatEvent.AI_START_SPEAKING, () => {
    audioService.playAudio();
});

// 音频队列播放完毕 → 回到 IDLE
audioService.onQueueEmpty(() => {
    chatStateManager.setState(ChatState.IDLE);
});
```

### 1.6 服务端音频到达时的处理

```typescript
// App.vue - onAudioMessage
async onAudioMessage(audioBuffer: AudioBuffer) {
    switch (chatStateManager.currentState.value as ChatState) {
        case ChatState.USER_SPEAKING:
            // 用户说话时收到音频 → 入队但不播放（可能是时序问题）
            audioService.enqueueAudio(audioBuffer);
            break;
        case ChatState.IDLE:
            // 空闲时收到音频 → 入队 + 切换到 AI_SPEAKING
            audioService.enqueueAudio(audioBuffer);
            chatStateManager.setState(ChatState.AI_SPEAKING);
            break;
        case ChatState.AI_SPEAKING:
            // AI 说话中 → 继续入队播放
            audioService.enqueueAudio(audioBuffer);
            break;
    }
},
```

### 1.7 完整一轮对话流程

```
═══ 第一轮：用户说话 → AI 回复 ═══

1. 状态: IDLE，麦克风持续采集
2. 用户说话 → audioLevel > 0.04
3. → IDLE → USER_SPEAKING
4.   发送 listen(start, mode:auto)
5.   停止播放，清空音频队列
6.   每帧音频发送到服务端（持续）
7.   静音检测：audioLevel < 0.04 → 启动 1s 计时器
8.   仍在说话：audioLevel >= 0.04 → 取消计时器
9.   最终静音 1 秒 → 计时器触发
10. → USER_SPEAKING → AI_SPEAKING
11.  发送 listen(stop, mode:auto)
12.  状态: AI_SPEAKING，麦克风仍在采集
13.  服务端返回: stt → llm → tts(sentence_start) → 二进制音频...
14.  收到音频 → 入队播放
15.  用户如果此时说话 → audioLevel > 0.1 → 发送 abort → 回到 USER_SPEAKING
16.  如果用户不打断 → 全部音频播完 → 队列空
17. → AI_SPEAKING → IDLE
18. 状态: IDLE，等待下一轮

═══ 手动打断 ═══

任何时候用户按打断按钮 → sendAbortMessage()
  → 如果 AI_SPEAKING: 停止播放，清空队列，回到 USER_SPEAKING
  → 如果 USER_SPEAKING: 无效果（已经在录音）
```

### 1.8 挂断通话

```typescript
// App.vue - closeVoiceCallPanel()
const closeVoiceCallPanel = async () => {
    isVoiceCallVisible.value = false;
    subtitleMessages.value = [];
    sendAbortMessage();          // 发送 abort
    audioService.stopMediaResources();  // 停止麦克风采集
};
```

---

## 二、Android 客户端当前问题

### 2.1 第一轮已修复（P0）的问题

| # | 问题 | 状态 |
|---|------|------|
| 1 | WebSocket 从未连接 | ✅ 已修复 |
| 2 | hello 后发送了错误的 speak 消息 | ✅ 已修复 |
| 3 | 等待不存在的 start 消息 | ✅ 已修复 |
| 4 | hello 后不开始录音 | ✅ 已修复 |

### 2.2 当前仍未修复的核心问题

#### 问题 A：缺少音频电平检测，状态永远卡在 userSpeaking

**现象**：log 一直显示 `[VoiceCall] 收到音频, 但 userSpeaking 中，忽略`

**原因**：

当前代码 `_startVoiceCallRecording()` 直接把状态设为 `userSpeaking` 并开始录音，但：
1. **没有音频电平检测** → 无法判断用户是否在说话
2. **没有静音计时器** → 无法自动从 userSpeaking 转换到 aiSpeaking
3. 状态永远卡在 userSpeaking → 收到的服务端音频全被忽略

WebUI 中，麦克风持续采集，每帧音频都经过 `detectAudioLevel()` 计算电平，然后喂给状态机的 `handleAudioLevel()`。状态机根据电平值决定转换。Android 完全缺少这个机制。

#### 问题 B：AI 播放时麦克风已停止，无法检测用户打断

**现象**：AI 回复时用户说话，无法自动打断 AI

**原因**：

当前代码在收到服务端音频时（`_handleReceivedAudio`），如果是 `idle` 状态，会调用 `_stopRecordingAndSendListenStop()` 停止录音。这意味着 AI_SPEAKING 期间麦克风是关闭的，无法检测用户是否在说话。

WebUI 中，**麦克风在整个通话期间始终保持开启**，即使在 AI_SPEAKING 状态也会持续采集音频，用于检测用户打断（audioLevel > 0.1）。

---

## 三、Android 修复方案

### 3.1 核心思路：麦克风全时开启 + 电平检测驱动状态机

完全对齐 WebUI 的架构：
1. **进入通话后立即开始录音，整个通话期间不停止**
2. **每一帧 PCM 音频计算电平** → 喂给状态机
3. **状态机根据电平自动转换** → 发送对应消息
4. **收到服务端音频时根据状态处理** → 入队播放

### 3.2 修改文件清单

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `lib/utils/audio_util.dart` | **新增** | 暴露 PCM 电平检测流 |
| `lib/services/xiaozhi_service.dart` | **大改** | 状态机 + 电平检测驱动 + 全时录音 |

### 3.3 `audio_util.dart` 修改：暴露音频电平流

**问题**：当前 `AudioUtil` 只暴露 Opus 编码后的音频流（`audioStream`），不暴露原始 PCM 数据。需要 PCM 数据来计算音频电平。

**修改方案**：新增一个 `audioLevelStream`，在录音回调中从 PCM 数据计算电平并发布。

```dart
// 新增字段
static final StreamController<double> _audioLevelController =
    StreamController<double>.broadcast();
static Stream<double> get audioLevelStream => _audioLevelController.stream;

// 修改 startRecording() 中的 stream listener
stream.listen(
  (data) async {
    if (data.isNotEmpty && data.length % 2 == 0) {
      // ★ 新增：计算音频电平（从 PCM16 数据）
      final level = _computeAudioLevel(data);
      _audioLevelController.add(level);

      // 原有：编码并发送
      final opusData = await encodeToOpus(data);
      if (opusData != null) {
        _audioStreamController.add(opusData);
      }
    }
  },
  // ...
);

/// 计算 PCM16 音频电平（与 WebUI detectAudioLevel 对齐）
/// WebUI 用 Float32Array [-1.0, 1.0]，Android 用 PCM16 [-32768, 32767]
/// 归一化后算法一致：sum(|sample|) / count
static double _computeAudioLevel(Uint8List pcmData) {
  int sampleCount = pcmData.length ~/ 2;
  if (sampleCount == 0) return 0.0;
  double sum = 0;
  for (int i = 0; i < pcmData.length; i += 2) {
    // PCM16 小端字节序
    int sample = pcmData[i] | (pcmData[i + 1] << 8);
    // 有符号转换
    if (sample >= 32768) sample -= 65536;
    sum += sample.abs();
  }
  return sum / sampleCount / 32768.0;  // 归一化到 0~1，与 WebUI 对齐
}
```

### 3.4 `xiaozhi_service.dart` 修改：完整状态机

#### 核心改造：录音全时开启 + 电平检测驱动

```dart
// 新增字段
StreamSubscription? _audioLevelSubscription;  // 音频电平订阅
Timer? _silenceTimer;                         // 静音计时器

// 阈值（与 WebUI 对齐）
static const double _userSpeakingThreshold = 0.04;   // 用户说话阈值
static const double _userInterruptThreshold = 0.1;   // 用户打断 AI 阈值
static const int _silenceTimeoutMs = 1000;            // 静音超时 1 秒
```

#### `_handleAudioLevel()` - 核心：每一帧音频的处理（对齐 WebUI handleAudioLevel）

```dart
/// 处理每一帧音频的电平值（对应 WebUI chatStateManager.handleUserAudioLevel）
void _handleAudioLevel(double audioLevel) {
  if (!_isVoiceCallActive) return;

  switch (_voiceCallState) {
    case VoiceCallState.idle:
      _handleAudioLevelInIdle(audioLevel);
      break;
    case VoiceCallState.userSpeaking:
      _handleAudioLevelInUserSpeaking(audioLevel);
      break;
    case VoiceCallState.aiSpeaking:
      _handleAudioLevelInAiSpeaking(audioLevel);
      break;
  }
}

/// IDLE 状态：检测用户是否开始说话
void _handleAudioLevelInIdle(double audioLevel) {
  if (audioLevel > _userSpeakingThreshold) {  // > 0.04
    print('[VoiceCall] IDLE → USER_SPEAKING (audioLevel=$audioLevel)');
    _setState(VoiceCallState.userSpeaking);
  }
}

/// USER_SPEAKING 状态：发送音频 + 静音检测
void _handleAudioLevelInUserSpeaking(double audioLevel) {
  // 不管电平高低，音频流会自动发送（因为录音一直在跑）
  // 这里只需要检测静音

  if (audioLevel < _userSpeakingThreshold) {  // < 0.04 静音
    if (_silenceTimer == null) {
      print('[VoiceCall] 检测到静音，启动 ${_silenceTimeoutMs}ms 计时器');
      _silenceTimer = Timer(Duration(milliseconds: _silenceTimeoutMs), () {
        print('[VoiceCall] 静音超时，USER_SPEAKING → AI_SPEAKING');
        _silenceTimer = null;
        _setState(VoiceCallState.aiSpeaking);
      });
    }
  } else {  // >= 0.04 还在说话
    if (_silenceTimer != null) {
      print('[VoiceCall] 用户仍在说话，取消静音计时器');
      _silenceTimer?.cancel();
      _silenceTimer = null;
    }
  }
}

/// AI_SPEAKING 状态：检测用户打断
void _handleAudioLevelInAiSpeaking(double audioLevel) {
  if (audioLevel > _userInterruptThreshold) {  // > 0.1 用户打断
    print('[VoiceCall] 用户打断 AI (audioLevel=$audioLevel), AI_SPEAKING → USER_SPEAKING');
    // 发送 abort
    if (_sessionId != null && _webSocketManager != null) {
      final abortMessage = {'session_id': _sessionId, 'type': 'abort'};
      _webSocketManager?.sendMessage(jsonEncode(abortMessage));
      print('[VoiceCall] 已发送 → abort');
    }
    // 停止播放、清空队列
    AudioUtil.stopPlaying();
    // 切换到 USER_SPEAKING
    _setState(VoiceCallState.userSpeaking);
  }
}
```

#### `_setState()` - 统一的状态转换方法（对齐 WebUI ChatStateManager.setState）

```dart
/// 统一的状态转换（对应 WebUI setState：先 onExit 旧状态，再 onEnter 新状态）
void _setState(VoiceCallState newState) {
  final oldState = _voiceCallState;
  print('[VoiceCall] 状态转换: $oldState → $newState');

  // 旧状态退出
  _onExitState(oldState);

  // 更新状态
  _voiceCallState = newState;

  // 新状态进入
  _onEnterState(newState, oldState);
}

/// 状态退出处理（对应 WebUI 各状态的 onExit）
void _onExitState(VoiceCallState state) {
  switch (state) {
    case VoiceCallState.userSpeaking:
      // 取消静音计时器
      _silenceTimer?.cancel();
      _silenceTimer = null;
      // 发送 listen(stop)
      if (_webSocketManager != null && _webSocketManager!.isConnected) {
        final message = {'type': 'listen', 'state': 'stop', 'mode': 'auto'};
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('[VoiceCall] onExit USER_SPEAKING: 已发送 → listen(stop)');
      }
      break;
    case VoiceCallState.aiSpeaking:
      // AI_SPEAKING 退出时，WebUI emit AI_STOP_SPEAKING
      // Android 不需要特殊处理
      break;
    case VoiceCallState.idle:
      break;
  }
}

/// 状态进入处理（对应 WebUI 各状态的 onEnter）
void _onEnterState(VoiceCallState newState, VoiceCallState oldState) {
  switch (newState) {
    case VoiceCallState.userSpeaking:
      if (oldState == VoiceCallState.userSpeaking) return;  // 避免重复进入
      // 发送 listen(start)
      if (_webSocketManager != null && _webSocketManager!.isConnected) {
        final message = {'type': 'listen', 'state': 'start', 'mode': 'auto'};
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('[VoiceCall] onEnter USER_SPEAKING: 已发送 → listen(start)');
      }
      // WebUI: USER_START_SPEAKING → stopPlaying + clearAudioQueue
      AudioUtil.stopPlaying();
      break;

    case VoiceCallState.aiSpeaking:
      if (oldState == VoiceCallState.aiSpeaking) return;  // 避免重复进入
      // WebUI: AI_START_SPEAKING → playAudio()
      // Android: 播放由 _handleReceivedAudio 直接触发，这里无需额外操作
      print('[VoiceCall] onEnter AI_SPEAKING: 等待服务端音频');
      break;

    case VoiceCallState.idle:
      // WebUI: 不做特殊处理
      break;
  }
}
```

#### 修改 `_handleReceivedAudio()` - 收到服务端音频时的处理

```dart
void _handleReceivedAudio(Uint8List audioData) {
  switch (_voiceCallState) {
    case VoiceCallState.idle:
      // 空闲时收到音频 → 切换到 AI_SPEAKING → 播放
      _setState(VoiceCallState.aiSpeaking);
      AudioUtil.playOpusData(audioData);
      print('[VoiceCall] 收到音频: IDLE → AI_SPEAKING, 开始播放');
      break;

    case VoiceCallState.userSpeaking:
      // 用户说话时收到音频 → 入队但不播放（WebUI 行为一致）
      // 这种情况通常是时序问题：服务端已经处理完了但客户端还没检测到静音
      print('[VoiceCall] 收到音频: USER_SPEAKING, 入队不播放');
      // 注意：当前 Android 没有音频队列，这里暂时忽略
      // 状态机会在 1 秒静音后自动切换到 AI_SPEAKING
      break;

    case VoiceCallState.aiSpeaking:
      // AI 说话中 → 继续播放
      AudioUtil.playOpusData(audioData);
      break;
  }
}
```

#### 修改 hello 处理：开始全时录音 + 订阅电平流

```dart
case 'hello':
  print('[VoiceCall] ← hello, session_id=$_sessionId');
  if (_isVoiceCallActive) {
    _startFullTimeRecording();  // ← 改名：全时录音（不再绑定状态转换）
  }
  break;
```

#### `_startFullTimeRecording()` - 全时录音 + 电平订阅

```dart
/// 开始全时录音（整个通话期间不停止，麦克风持续采集）
Future<void> _startFullTimeRecording() async {
  try {
    print('[VoiceCall] 开始全时录音...');

    // 开始录音
    await AudioUtil.startRecording();
    print('[VoiceCall] AudioUtil.startRecording 完成');

    // 订阅 Opus 音频流 → 发送到 WebSocket
    _audioStreamSubscription = AudioUtil.audioStream.listen((opusData) {
      // ★ 只在 USER_SPEAKING 时发送音频到服务端
      // （WebUI 也是这样：sendAudioData 只在 USER_SPEAKING 的 handleAudioLevel 中调用）
      if (_voiceCallState == VoiceCallState.userSpeaking) {
        _webSocketManager?.sendBinaryMessage(opusData);
      }
    });
    print('[VoiceCall] Opus 音频流订阅已建立');

    // 订阅音频电平流 → 驱动状态机
    _audioLevelSubscription = AudioUtil.audioLevelStream.listen((level) {
      _handleAudioLevel(level);
    });
    print('[VoiceCall] 音频电平检测已启动');

    // 初始状态设为 IDLE（等待用户说话，而不是直接 USER_SPEAKING）
    _voiceCallState = VoiceCallState.idle;
    print('[VoiceCall] 初始状态: IDLE, 等待用户说话 (audioLevel > 0.04)');
  } catch (e) {
    print('[VoiceCall] 开始录音失败: $e');
  }
}
```

#### 修改 `disconnectVoiceCall()` - 停止全时录音

```dart
Future<void> disconnectVoiceCall() async {
  // 取消电平订阅
  _audioLevelSubscription?.cancel();
  _audioLevelSubscription = null;

  // 取消静音计时器
  _silenceTimer?.cancel();
  _silenceTimer = null;

  // 停止录音（全时录音终于停了）
  if (AudioUtil.isRecording) {
    await AudioUtil.stopRecording();
  }

  // 停止播放
  await AudioUtil.stopPlaying();

  // 取消 Opus 流订阅
  await _audioStreamSubscription?.cancel();
  _audioStreamSubscription = null;

  // 断开 WebSocket
  await disconnect();

  _isVoiceCallActive = false;
  _voiceCallState = VoiceCallState.idle;
}
```

### 3.5 `voice_call_screen.dart` 修改

无需额外修改，现有代码已经通过 `_xiaozhiService.voiceCallState` 读取状态。

---

## 四、完整协议流程（修正版）

```
Android Client                           Server
    │                                       │
    │── WebSocket Connect ──────────────────►│
    │◄── hello (session_id) ───────────────│
    │                                       │
    │  [开始全时录音 + 电平检测]             │
    │  [状态 = IDLE, 等待 audioLevel>0.04]  │
    │                                       │
    │  用户说话: audioLevel > 0.04           │
    │  ───────────────────────────           │
    │  状态: IDLE → USER_SPEAKING           │
    │── listen(start, mode:auto) ──────────►│
    │── binary (Opus) ────────────────────►│  ← 每帧都发
    │── binary (Opus) ────────────────────►│
    │── binary (Opus) ────────────────────►│
    │                                       │
    │  用户安静: audioLevel < 0.04 持续1s   │
    │  ───────────────────────────           │
    │  状态: USER_SPEAKING → AI_SPEAKING    │
    │── listen(stop, mode:auto) ───────────►│
    │  [麦克风仍在采集，检测打断]            │
    │                                       │
    │◄── stt (text: "...") ────────────────│
    │◄── llm (text: "...") ────────────────│
    │◄── tts (sentence_start) ─────────────│
    │◄── binary (Opus audio) ──────────────│  ← 播放
    │◄── binary (Opus audio) ──────────────│
    │◄── tts (state: stop) ───────────────│
    │                                       │
    │  状态: AI_SPEAKING → IDLE             │
    │  [继续等待用户说话]                    │
    │                                       │
    │  ══ 或者：AI 播放时用户打断 ══        │
    │  audioLevel > 0.1                     │
    │── abort (session_id) ────────────────►│
    │  状态: AI_SPEAKING → USER_SPEAKING    │
    │── listen(start, mode:auto) ──────────►│
    │── binary (Opus) ────────────────────►│
    │                                       │
    │  [用户挂断]                            │
    │── abort + stopRecording + disconnect  │
```

---

## 五、实现优先级（更新版）

1. **P0 - 已完成**
   - WebSocket 连接
   - 删除 speak/start 错误消息
   - hello 后开始录音

2. **P1 - 当前要实现（通话循环的核心）**
   - `audio_util.dart`: 新增 `_computeAudioLevel()` + `audioLevelStream`
   - `xiaozhi_service.dart`: 全时录音（不再按状态停止/启动录音）
   - `xiaozhi_service.dart`: `_handleAudioLevel()` 状态机（IDLE/USER_SPEAKING/AI_SPEAKING）
   - `xiaozhi_service.dart`: `_setState()` 统一状态转换 + onEnter/onExit
   - `xiaozhi_service.dart`: 静音 1s 计时器 → USER_SPEAKING → AI_SPEAKING
   - `xiaozhi_service.dart`: AI 播放时检测用户打断（audioLevel > 0.1）

3. **P2 - 后续优化**
   - 用户打断时收到 AI 音频的缓冲播放
   - UI 动画与状态机同步优化
