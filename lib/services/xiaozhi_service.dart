import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import '../services/xiaozhi_websocket_manager.dart';
import '../utils/audio_util.dart';
import 'device_mcp_tools.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 小智服务事件类型
enum XiaozhiServiceEventType {
  connected,
  disconnected,
  textMessage,
  audioData,
  error,
  voiceCallStart,
  voiceCallEnd,
  userMessage,
  firmwareUpdate,
}

/// 语音通话状态（参考 WebUI ChatStateManager）
enum VoiceCallState {
  idle,          // 空闲，等待用户说话
  userSpeaking,  // 用户正在说话，录音并发送音频
  aiSpeaking,    // AI 正在回复，播放 TTS 音频
}

/// 小智服务事件
class XiaozhiServiceEvent {
  final XiaozhiServiceEventType type;
  final dynamic data;

  XiaozhiServiceEvent(this.type, this.data);
}

/// 小智服务监听器
typedef XiaozhiServiceListener = void Function(XiaozhiServiceEvent event);

/// 消息监听器
typedef MessageListener = void Function(dynamic message);

/// 小智服务
class XiaozhiService {
  static const String TAG = "XiaozhiService";

  // 单例实例
  static XiaozhiService? _instance;

  final String macAddress;
  final String otaUrl;
  final String clientId;
  final String wsUrl;
  final String configType;
  final String lang;
  final String firmwareVersion; // 设备当前固件版本（'-1'=未安装哨兵），传给 manager 上报 OTA
  String? _sessionId;

  XiaozhiWebSocketManager? _webSocketManager;
  final DeviceMcpTools _mcpTools = DeviceMcpTools();
  bool _isConnected = false;
  bool _isMuted = false;
  final List<XiaozhiServiceListener> _listeners = [];
  StreamSubscription? _audioStreamSubscription;
  StreamSubscription? _audioLevelSubscription;
  bool _isVoiceCallActive = false;
  WebSocketChannel? _ws;
  MessageListener? _messageListener;

  // 状态机（参考 WebUI ChatStateManager）
  VoiceCallState _voiceCallState = VoiceCallState.idle;
  Timer? _silenceTimer;

  // 阈值（与 WebUI 对齐）
  static const double _userSpeakingThreshold = 0.04;  // 用户说话阈值
  static const double _userInterruptThreshold = 0.03;  // 用户打断 AI 阈值（AI播放时AEC压低增益，需更低阈值）
  static const int _silenceTimeoutMs = 1000;           // 静音超时 1 秒
  static const int _interruptFrames = 3;               // 打断确认帧数（约 180ms）

  // 调试计数器
  int _audioLevelCount = 0;
  int _interruptCandidateCount = 0; // 连续超过打断阈值的帧计数

  /// 工厂构造函数，实现单例模式
  factory XiaozhiService({
    required String macAddress,
    required String otaUrl,
    required String clientId,
    required String wsUrl,
    String configType = 'official',
    String lang = 'zh-CN',
    String firmwareVersion = '-1',
    String? sessionId,
  }) {
    _instance ??= XiaozhiService._internal(
      macAddress: macAddress,
      otaUrl: otaUrl,
      clientId: clientId,
      wsUrl: wsUrl,
      configType: configType,
      lang: lang,
      firmwareVersion: firmwareVersion,
      sessionId: sessionId,
    );
    return _instance!;
  }

  /// 内部构造函数
  XiaozhiService._internal({
    required this.macAddress,
    required this.otaUrl,
    required this.clientId,
    required this.wsUrl,
    required this.configType,
    this.lang = 'zh-CN',
    this.firmwareVersion = '-1',
    String? sessionId,
  }) {
    _sessionId = sessionId;
    _init();
  }

  /// 获取实例
  static XiaozhiService? get instance => _instance;

  /// 重置单例
  static void resetInstance() {
    _instance = null;
  }

  /// 获取当前语音通话状态（供 UI 读取）
  VoiceCallState get voiceCallState => _voiceCallState;

  /// 初始化
  Future<void> _init() async {
    print('[VoiceCall] XiaozhiService 初始化: mac=$macAddress, otaUrl=$otaUrl, clientId=$clientId, wsUrl=$wsUrl');

    _webSocketManager = XiaozhiWebSocketManager(
      deviceId: macAddress,
      otaUrl: otaUrl,
      clientId: clientId,
      wsUrl: wsUrl,
      configType: configType,
      lang: lang,
      firmwareVersion: firmwareVersion,
    );
    _webSocketManager!.addListener(_onWebSocketEvent);
    // 把设备 MAC 注入 MCP 工具，供 TakePhotoTool 上传 worker 时当 Device-Id
    _mcpTools.macAddress = macAddress;

    await AudioUtil.initRecorder();
    await AudioUtil.initPlayer();
  }

  // ========== 对外接口 ==========

  /// 设置消息监听器
  void setMessageListener(MessageListener listener) {
    _messageListener = listener;
  }

  void addListener(XiaozhiServiceListener listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  void removeListener(XiaozhiServiceListener listener) {
    _listeners.remove(listener);
  }

  void _dispatchEvent(XiaozhiServiceEvent event) {
    for (var listener in _listeners) {
      listener(event);
    }
  }

  /// 连接普通聊天
  Future<void> connect() async {
    if (_isConnected) return;
    try {
      _webSocketManager = XiaozhiWebSocketManager(
        deviceId: macAddress, otaUrl: otaUrl,
        clientId: clientId, wsUrl: wsUrl, configType: configType, lang: lang,
        firmwareVersion: firmwareVersion,
      );
      _webSocketManager!.addListener(_onWebSocketEvent);
      await _webSocketManager!.connect();
    } catch (e) {
      print('[VoiceCall] 连接失败: $e');
      _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.error, '连接失败: $e'));
    }
  }

  /// 连接语音通话（参考 WebUI showVoiceCallPanel）
  Future<void> connectVoiceCall() async {
    try {
      if (Platform.isIOS || Platform.isAndroid) {
        final status = await Permission.microphone.request();
        if (status != PermissionStatus.granted) {
          _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.error, '麦克风权限被拒绝'));
          return;
        }
      }

      _isVoiceCallActive = true;
      _voiceCallState = VoiceCallState.idle;

      print('[VoiceCall] connectVoiceCall: _isVoiceCallActive=true, state=idle');

      await AudioUtil.stopPlaying();
      await AudioUtil.initRecorder();
      await AudioUtil.initPlayer();

      _webSocketManager = XiaozhiWebSocketManager(
        deviceId: macAddress, otaUrl: otaUrl,
        clientId: clientId, wsUrl: wsUrl, configType: configType, lang: lang,
        firmwareVersion: firmwareVersion,
      );
      _webSocketManager!.addListener(_onWebSocketEvent);
      await _webSocketManager!.connect();

      print('[VoiceCall] WebSocket 连接完成，等待 hello...');
    } catch (e) {
      print('[VoiceCall] 连接失败: $e');
      _isVoiceCallActive = false;
      _voiceCallState = VoiceCallState.idle;
      rethrow;
    }
  }

  /// 断开语音通话
  Future<void> disconnectVoiceCall() async {
    print('[VoiceCall] 断开语音通话');

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

  /// 断开连接
  Future<void> disconnect() async {
    if (!_isConnected || _webSocketManager == null) return;
    try {
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;
      if (AudioUtil.isRecording) {
        await AudioUtil.stopRecording();
      }
      await _webSocketManager!.disconnect();
      _webSocketManager = null;
      _isConnected = false;
    } catch (e) {
      print('[VoiceCall] 断开连接失败: $e');
    }
  }

  /// 发送中断消息（参考 WebUI AbortMessage）
  Future<void> sendAbortMessage() async {
    try {
      if (_webSocketManager != null && _isConnected && _sessionId != null) {
        final abortMessage = {
          'session_id': _sessionId,
          'type': 'abort',
        };
        _webSocketManager?.sendMessage(jsonEncode(abortMessage));
        print('[VoiceCall] 已发送 → abort (session_id=$_sessionId)');

        // 如果 AI 正在说话，停止播放
        if (_voiceCallState == VoiceCallState.aiSpeaking) {
          AudioUtil.mutePlayback();
          // 注意：不切换状态，状态机会通过电平检测自动处理
        }
      }
    } catch (e) {
      print('[VoiceCall] 发送 abort 失败: $e');
    }
  }

  /// 切换到普通聊天模式
  Future<void> switchToChatMode() async {
    if (!_isVoiceCallActive) return;
    await disconnectVoiceCall();
  }

  /// 中断音频播放
  Future<void> stopPlayback() async {
    try {
      await AudioUtil.stopPlaying();
    } catch (e) {
      print('[VoiceCall] 停止播放失败: $e');
    }
  }

  bool get isConnected => _isConnected && _webSocketManager != null && _webSocketManager!.isConnected;
  bool get isMuted => _isMuted;
  bool get isVoiceCallActive => _isVoiceCallActive;

  /// 开始监听（按住说话模式，供 chat_screen.dart 使用）
  Future<void> startListening({String mode = 'manual'}) async {
    if (!_isConnected || _webSocketManager == null) {
      await connect();
    }
    if (_sessionId == null) return;
    await AudioUtil.startRecording();
    final message = {
      'session_id': _sessionId,
      'type': 'listen',
      'state': 'start',
      'mode': mode,
    };
    _webSocketManager?.sendMessage(jsonEncode(message));
    _audioStreamSubscription = AudioUtil.audioStream.listen((opusData) {
      _webSocketManager?.sendBinaryMessage(opusData);
    });
  }

  /// 停止监听（按住说话模式，供 chat_screen.dart 使用）
  Future<void> stopListening() async {
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
    await AudioUtil.stopRecording();
    if (_sessionId != null && _webSocketManager != null) {
      final message = {
        'session_id': _sessionId,
        'type': 'listen',
        'state': 'stop',
      };
      _webSocketManager?.sendMessage(jsonEncode(message));
    }
  }

  /// 取消发送（供 chat_screen.dart 使用）
  Future<void> abortListening() async {
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
    await AudioUtil.stopRecording();
    if (_sessionId != null && _webSocketManager != null) {
      final message = {'session_id': _sessionId, 'type': 'abort'};
      _webSocketManager?.sendMessage(jsonEncode(message));
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await AudioUtil.dispose();
    _listeners.clear();
  }

  /// 发送文本消息
  Future<String> sendTextMessage(String message) async {
    if (!_isConnected && _webSocketManager == null) {
      await connect();
    }
    try {
      final completer = Completer<String>();
      void onceListener(XiaozhiServiceEvent event) {
        if (event.type == XiaozhiServiceEventType.textMessage) {
          if (event.data == message) return;
          if (!completer.isCompleted) {
            print('[xz_dbg] ← sendText 收到回复');
            completer.complete(event.data as String);
            removeListener(onceListener);
          }
        } else if (event.type == XiaozhiServiceEventType.error && !completer.isCompleted) {
          completer.completeError(event.data.toString());
          removeListener(onceListener);
        }
      }
      addListener(onceListener);
      _webSocketManager!.sendTextRequest(message);
      if (configType == 'worker') {
        print('[xz_dbg] → sendText: "$message" (等回复, 15s)');
      }
      final timeoutTimer = Timer(const Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          if (configType == 'worker') {
            print('[xz_dbg] ✗ sendText 请求超时（15s 无 textMessage 回复）: "$message"');
          }
          completer.completeError('请求超时');
          removeListener(onceListener);
        }
      });
      try {
        final result = await completer.future;
        timeoutTimer.cancel();
        return result;
      } catch (e) {
        timeoutTimer.cancel();
        rethrow;
      }
    } catch (e) {
      rethrow;
    }
  }

  // ========== 核心状态机（对齐 WebUI ChatStateManager） ==========

  /// 开始全时录音（整个通话期间不停止）
  /// 对应 WebUI: prepareMediaResources() → AudioWorklet 持续采集
  Future<void> _startFullTimeRecording() async {
    try {
      print('[VoiceCall] 开始全时录音（麦克风在整个通话期间保持开启）...');

      await AudioUtil.startRecording();
      print('[VoiceCall] AudioUtil.startRecording 完成');

      // 订阅 Opus 音频流 → 只在 USER_SPEAKING 时发送到服务端
      // （WebUI 也是：sendAudioData 只在 USER_SPEAKING 的 handleAudioLevel 中调用）
      _audioStreamSubscription = AudioUtil.audioStream.listen((opusData) {
        if (_voiceCallState == VoiceCallState.userSpeaking &&
            _webSocketManager != null &&
            _webSocketManager!.isConnected) {
          _webSocketManager!.sendBinaryMessage(opusData);
        }
      });
      print('[VoiceCall] Opus 音频流订阅已建立（仅 USER_SPEAKING 时发送）');

      // 订阅音频电平流 → 驱动状态机
      // 对应 WebUI: audioService.onProcess → chatStateManager.handleUserAudioLevel
      _audioLevelSubscription = AudioUtil.audioLevelStream.listen((level) {
        _handleAudioLevel(level);
      });
      print('[VoiceCall] 音频电平检测已启动 (阈值: speak=$_userSpeakingThreshold, interrupt=$_userInterruptThreshold, silence=${_silenceTimeoutMs}ms)');

      // 初始状态 IDLE（等待用户说话，对齐 WebUI）
      _voiceCallState = VoiceCallState.idle;
      print('[VoiceCall] 初始状态: IDLE, 等待 audioLevel > $_userSpeakingThreshold');
    } catch (e) {
      print('[VoiceCall] 开始录音失败: $e');
    }
  }

  /// 处理每一帧音频的电平值（对应 WebUI chatStateManager.handleUserAudioLevel）
  void _handleAudioLevel(double audioLevel) {
    if (!_isVoiceCallActive) return;

    // 每 50 帧打印一次电平值（约每 3 秒），方便调试
    _audioLevelCount++;
    if (_audioLevelCount % 50 == 0) {
      print('[VoiceCall] audioLevel debug: level=${audioLevel.toStringAsFixed(4)}, state=$_voiceCallState, count=$_audioLevelCount');
    }

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
    if (audioLevel > _userSpeakingThreshold) {
      print('[VoiceCall] IDLE → USER_SPEAKING (audioLevel=${audioLevel.toStringAsFixed(3)})');
      _setState(VoiceCallState.userSpeaking);
    }
  }

  /// USER_SPEAKING 状态：发送音频 + 静音检测
  void _handleAudioLevelInUserSpeaking(double audioLevel) {
    // 音频已通过 _audioStreamSubscription 在 USER_SPEAKING 时自动发送
    // 这里只需要检测静音（对应 WebUI ChatStateManager USER_SPEAKING.handleAudioLevel）

    if (audioLevel < _userSpeakingThreshold) {
      // 静音：启动计时器
      if (_silenceTimer == null) {
        print('[VoiceCall] 检测到静音，启动 ${_silenceTimeoutMs}ms 计时器');
        _silenceTimer = Timer(Duration(milliseconds: _silenceTimeoutMs), () {
          print('[VoiceCall] 静音超时，USER_SPEAKING → AI_SPEAKING');
          _silenceTimer = null;
          _setState(VoiceCallState.aiSpeaking);
        });
      }
    } else {
      // 还在说话：取消计时器
      if (_silenceTimer != null) {
        _silenceTimer?.cancel();
        _silenceTimer = null;
      }
    }
  }

  /// AI_SPEAKING 状态：检测用户打断
  void _handleAudioLevelInAiSpeaking(double audioLevel) {
    if (audioLevel > _userInterruptThreshold) {
      _interruptCandidateCount++;
      if (_interruptCandidateCount >= _interruptFrames) {
        print('[VoiceCall] 用户打断 AI (audioLevel=${audioLevel.toStringAsFixed(3)}, 连续${_interruptCandidateCount}帧), AI_SPEAKING → USER_SPEAKING');
        _interruptCandidateCount = 0;

        // 发送 abort（对应 WebUI ChatStateManager AI_SPEAKING.handleAudioLevel）
        if (_sessionId != null && _webSocketManager != null && _webSocketManager!.isConnected) {
          final abortMessage = {'session_id': _sessionId, 'type': 'abort'};
          _webSocketManager?.sendMessage(jsonEncode(abortMessage));
          print('[VoiceCall] 已发送 → abort (用户打断)');
        }

        // 停止播放、清空队列（对应 WebUI USER_START_SPEAKING 事件处理）
        // Android: 不销毁播放器，改用静音（避免 AudioTrack 无法重建的问题）
        AudioUtil.mutePlayback();

        // 切换到 USER_SPEAKING
        _setState(VoiceCallState.userSpeaking);
      }
    } else {
      // 低于阈值，重置计数
      if (_interruptCandidateCount > 0) {
        _interruptCandidateCount = 0;
      }
    }
  }

  /// 统一的状态转换（对应 WebUI ChatStateManager.setState）
  /// 先 onExit 旧状态，再 onEnter 新状态
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
        // 发送 listen(stop)（对应 WebUI USER_SPEAKING.onExit → sendTextData(AIListening_Stop)）
        if (_webSocketManager != null && _webSocketManager!.isConnected) {
          final message = {'type': 'listen', 'state': 'stop', 'mode': 'auto'};
          _webSocketManager?.sendMessage(jsonEncode(message));
          print('[VoiceCall] onExit USER_SPEAKING: 已发送 → listen(stop)');
        }
        break;
      case VoiceCallState.aiSpeaking:
        // AI_SPEAKING 退出时，WebUI emit AI_STOP_SPEAKING，无需特殊处理
        break;
      case VoiceCallState.idle:
        break;
    }
  }

  /// 状态进入处理（对应 WebUI 各状态的 onEnter）
  void _onEnterState(VoiceCallState newState, VoiceCallState oldState) {
    switch (newState) {
      case VoiceCallState.userSpeaking:
        if (oldState == VoiceCallState.userSpeaking) return; // 避免重复进入
        // 发送 listen(start)（对应 WebUI USER_SPEAKING.onEnter → sendTextData(AIListening_Start)）
        if (_webSocketManager != null && _webSocketManager!.isConnected) {
          final message = {'type': 'listen', 'state': 'start', 'mode': 'auto'};
          _webSocketManager?.sendMessage(jsonEncode(message));
          print('[VoiceCall] onEnter USER_SPEAKING: 已发送 → listen(start)');
        }
        // 对应 WebUI: USER_START_SPEAKING → stopPlaying + clearAudioQueue
        // Android: 不销毁播放器（AudioTrack 重新创建会失败），改用静音
        AudioUtil.mutePlayback();
        break;

      case VoiceCallState.aiSpeaking:
        if (oldState == VoiceCallState.aiSpeaking) return; // 避免重复进入
        // 重置打断计数器
        _interruptCandidateCount = 0;
        // 对应 WebUI: AI_START_SPEAKING → playAudio()
        // Android: 播放由 _handleReceivedAudio 直接触发
        print('[VoiceCall] onEnter AI_SPEAKING: 等待服务端音频');
        break;

      case VoiceCallState.idle:
        break;
    }
  }

  // ========== WebSocket 事件处理 ==========

  /// 处理 WebSocket 事件
  void _onWebSocketEvent(XiaozhiEvent event) {
    switch (event.type) {
      case XiaozhiEventType.connected:
        _isConnected = true;
        print('[VoiceCall] WebSocket 连接成功');
        _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.connected, null));
        break;

      case XiaozhiEventType.disconnected:
        _isConnected = false;
        print('[VoiceCall] WebSocket 连接断开');
        _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.disconnected, null));
        break;

      case XiaozhiEventType.message:
        _handleTextMessage(event.data as String);
        break;

      case XiaozhiEventType.binaryMessage:
        final audioData = event.data as List<int>;
        _handleReceivedAudio(Uint8List.fromList(audioData));
        break;

      case XiaozhiEventType.error:
        print('[VoiceCall] WebSocket 错误: ${event.data}');
        _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.error, event.data));
        break;

      case XiaozhiEventType.firmwareUpdate:
        // manager 自动下载固件的结果（downloading/done/error），交给 UI 层 bump+持久化+刷新
        print('[VoiceCall] 固件升级事件: ${event.data}');
        _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.firmwareUpdate, event.data));
        break;
    }
  }

  /// 处理收到的音频数据（对应 WebUI onAudioMessage）
  void _handleReceivedAudio(Uint8List audioData) {
    switch (_voiceCallState) {
      case VoiceCallState.idle:
        // 空闲时收到音频 → 切换到 AI_SPEAKING → 播放
        print('[VoiceCall] 收到音频: IDLE → AI_SPEAKING, 开始播放');
        _setState(VoiceCallState.aiSpeaking);
        AudioUtil.unmutePlayback();
        AudioUtil.playOpusData(audioData);
        break;

      case VoiceCallState.userSpeaking:
        // 用户说话时收到音频（时序问题：服务端已处理但客户端还没检测到静音）
        // WebUI 行为：enqueueAudio（入队不播放）
        // Android 简化处理：忽略，状态机会在静音 1s 后自动切换
        print('[VoiceCall] 收到音频: USER_SPEAKING, 忽略（等待静音超时切换）');
        break;

      case VoiceCallState.aiSpeaking:
        // AI 说话中 → 继续播放（确保取消静音）
        AudioUtil.unmutePlayback();
        AudioUtil.playOpusData(audioData);
        break;
    }
  }

  /// 处理文本消息（对应 WebUI onTextMessage）
  void _handleTextMessage(String message) {
    print('[VoiceCall] ← 文本消息: $message');
    try {
      final Map<String, dynamic> jsonData = json.decode(message);
      final String type = jsonData['type'] ?? '';

      if (configType == 'worker') {
        print('[xz_dbg] ← msg type=$type');
      }

      // 先调用消息监听器
      if (_messageListener != null) {
        _messageListener!(jsonData);
      }

      // 更新 session_id
      if (jsonData['session_id'] != null) {
        _sessionId = jsonData['session_id'];
        print('[VoiceCall] session_id: $_sessionId');
      }

      switch (type) {
        case 'hello':
          // 收到 hello → 开始全时录音（对应 WebUI prepareMediaResources 后的状态）
          print('[VoiceCall] ← hello, session_id=$_sessionId');
          if (_isVoiceCallActive) {
            _startFullTimeRecording();
          }
          break;

        case 'stt':
          final String text = jsonData['text'] ?? '';
          if (text.isNotEmpty) {
            print('[VoiceCall] ← STT: $text');
            _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.userMessage, text));
          }
          break;

        case 'tts':
          final String state = jsonData['state'] ?? '';
          final String text = jsonData['text'] ?? '';
          if (state == 'sentence_start' && text.isNotEmpty) {
            print('[VoiceCall] ← TTS: $text');
            _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.textMessage, text));
          } else if (state == 'stop') {
            // TTS 播放结束 → 仅在 AI_SPEAKING 时才切换到 IDLE
            // 如果用户已打断（状态已是 USER_SPEAKING），不覆盖
            if (_voiceCallState == VoiceCallState.aiSpeaking) {
              print('[VoiceCall] ← TTS stop: AI_SPEAKING → IDLE');
              _setState(VoiceCallState.idle);
            } else {
              print('[VoiceCall] ← TTS stop: 忽略（当前状态=$_voiceCallState，非 AI_SPEAKING）');
            }
          }
          break;

        case 'llm':
          final String text = jsonData['text'] ?? '';
          final String emotion = jsonData['emotion'] ?? '';
          if (text.isNotEmpty) {
            print('[VoiceCall] ← LLM: $text (emotion=$emotion)');
            _dispatchEvent(XiaozhiServiceEvent(XiaozhiServiceEventType.textMessage, text));
          }
          break;

        case 'emotion':
          final String emotion = jsonData['emotion'] ?? '';
          if (emotion.isNotEmpty) {
            print('[VoiceCall] ← emotion: $emotion');
          }
          break;

        case 'mcp':
          // 自建 Worker：hello 声明了 features.mcp，上游会发起 MCP 握手，
          // 客户端作为 MCP 服务端必须回应，否则上游会一直挂起。
          _handleMcpMessage(jsonData);
          break;

        default:
          print('[VoiceCall] ← 未知消息: $type');
      }
    } catch (e) {
      print('[VoiceCall] 解析消息失败: $e');
    }
  }

  /// MCP 响应发送 helper：原样回传 session_id 和 payload.id（对齐 simulate.html）
  void _sendMcpResponse(Map<String, dynamic> jsonData, dynamic id,
      {Map<String, dynamic>? result, Map<String, dynamic>? error}) {
    final resp = <String, dynamic>{
      'type': 'mcp',
      'session_id': jsonData['session_id'],
      'payload': <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        if (result != null) 'result': result else if (error != null) 'error': error,
      },
    };
    _webSocketManager?.sendMessage(jsonEncode(resp));
  }

  /// 处理 MCP 消息（自建 Worker 模式）。
  /// 客户端作为 MCP 服务端，回应 initialize / tools/list / tools/call。
  /// tools/list 返回设备注册的工具；tools/call 派发执行并回结果。
  Future<void> _handleMcpMessage(Map<String, dynamic> jsonData) async {
    final payload = jsonData['payload'];
    if (payload is! Map<String, dynamic>) {
      print('[VoiceCall] ← mcp: payload 非对象，忽略');
      return;
    }

    final method = payload['method'] as String?;
    final id = payload['id']; // 可能是数字或 null

    // 通知（无 id）：仅记录，不回答
    if (id == null) {
      print('[VoiceCall] ← mcp notification: $method');
      return;
    }

    if (method == 'initialize') {
      print('[VoiceCall] → mcp initialize response id=$id');
      _sendMcpResponse(jsonData, id, result: {
        'protocolVersion': '2024-11-05',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'xiaozhi-android', 'version': '1.1.2'},
      });
      return;
    }

    if (method == 'tools/list') {
      final tools = _mcpTools.toolsList();
      print('[VoiceCall] → mcp tools/list response (count=${tools.length}) id=$id');
      _sendMcpResponse(jsonData, id, result: {'tools': tools});
      return;
    }

    if (method == 'tools/call') {
      final params = payload['params'];
      final toolName = (params is Map<String, dynamic>) ? (params['name'] ?? '') : '';
      final arguments = (params is Map<String, dynamic> && params['arguments'] is Map)
          ? Map<String, dynamic>.from(params['arguments'] as Map)
          : <String, dynamic>{};
      final t0 = DateTime.now();
      print('[xz_dbg] ← tools/call 收到: $toolName id=$id args=$arguments');
      final result = await _mcpTools.call(toolName.toString(), arguments);
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      if (result != null) {
        print('[xz_dbg] → tools/call 回传: $toolName (handler ${elapsed}ms) success=${result.success}: ${result.text}');
        _sendMcpResponse(jsonData, id, result: {
          'content': [{'type': 'text', 'text': result.text}],
          'isError': !result.success,
        });
        // worker 远程拍照触发（带 question）：给用户在对话里发一条提示，让用户知道
        final isWorkerCapture = toolName == 'self.camera.take_photo' &&
            arguments['question'] != null;
        if (isWorkerCapture) {
          final note = result.success
              ? '📷 收到 worker 远程拍照请求，已拍照并上传'
              : '📷 收到 worker 远程拍照请求，但未完成：${result.text}';
          _dispatchEvent(XiaozhiServiceEvent(
              XiaozhiServiceEventType.textMessage, note));
        }
      } else {
        print('[xz_dbg] → tools/call 未知工具: $toolName (${elapsed}ms)');
        _sendMcpResponse(jsonData, id,
            error: {'code': -32601, 'message': 'Unknown tool: $toolName'});
      }
      return;
    }

    // 其它带 id 的请求：统一回 method not found
    print('[VoiceCall] → mcp error (unhandled $method) id=$id');
    _sendMcpResponse(jsonData, id,
        error: {'code': -32601, 'message': 'Method not found: $method'});
  }
}
