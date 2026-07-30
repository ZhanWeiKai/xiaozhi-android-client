import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/models/message.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/services/xiaozhi_service.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:io';

class VoiceCallScreen extends StatefulWidget {
  final Conversation conversation;
  final XiaozhiConfig xiaozhiConfig;

  const VoiceCallScreen({
    super.key,
    required this.conversation,
    required this.xiaozhiConfig,
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen>
    with SingleTickerProviderStateMixin {
  late XiaozhiService _xiaozhiService;
  bool _isConnected = false;
  String _statusText = '正在连接...';
  Timer? _callTimer;
  Duration _callDuration = Duration.zero;
  bool _serverReady = false;

  late AnimationController _animationController;
  final List<double> _audioLevels = List.filled(30, 0.05);
  Timer? _audioVisualizerTimer;

  @override
  void initState() {
    super.initState();

    // 设置状态栏为透明并使图标为白色
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    // 在帧绘制后再次设置系统UI样式，避免被覆盖
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      );
    });

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    // 断开旧服务并重置单例，确保切换到新的服务配置
    XiaozhiService.resetInstance();

    // 获取XiaozhiService实例
    _xiaozhiService = XiaozhiService(
      macAddress: widget.xiaozhiConfig.macAddress,
      otaUrl: widget.xiaozhiConfig.otaUrl?.isNotEmpty == true
          ? widget.xiaozhiConfig.otaUrl!
          : ConfigProvider.OFFICIAL_OTA_URL,
      clientId: widget.xiaozhiConfig.clientId?.isNotEmpty == true
          ? widget.xiaozhiConfig.clientId!
          : const Uuid().v4(),
      wsUrl: widget.xiaozhiConfig.websocketUrl?.isNotEmpty == true
          ? widget.xiaozhiConfig.websocketUrl!
          : ConfigProvider.OFFICIAL_WS_URL,
      configType: widget.xiaozhiConfig.configType,
      lang: widget.xiaozhiConfig.lang,
      firmwareVersion: widget.xiaozhiConfig.firmwareVersion,
      sessionId: widget.conversation.id,
    );

    // 设置消息监听器
    _xiaozhiService.setMessageListener(_handleServerMessage);

    // 连接并切换到语音通话模式
    _connectToVoiceService();
    _startAudioVisualizer();
  }

  void _handleServerMessage(dynamic message) {
    if (message is! Map<String, dynamic>) return;

    final type = message['type'];
    print('[VoiceCallScreen] ← 收到消息: type=$type');

    if (type == 'hello') {
      print('[VoiceCallScreen] ← hello, 录音将由 service 自动开始');
      setState(() {
        _serverReady = true;
        _isConnected = true;
        _statusText = '已连接';
      });
      if (mounted) {
        _showCustomSnackbar(
          message: '已连接，正在开始录音...',
          icon: Icons.check_circle,
          iconColor: Colors.greenAccent,
        );
      }
    } else if (type == 'stt') {
      // 用户语音识别结果
      final text = message['text'] ?? '';
      if (text.isNotEmpty) {
        print('[VoiceCallScreen] ← STT: $text');
        _addMessage(text, MessageRole.user);
      }
    } else if (type == 'tts') {
      final state = message['state'] ?? '';
      final text = message['text'] ?? '';
      if (state == 'sentence_start' && text.isNotEmpty) {
        print('[VoiceCallScreen] ← TTS: $text');
        _addMessage(text, MessageRole.assistant);
        setState(() {
          _statusText = 'AI 回复中';
        });
      } else if (state == 'stop') {
        setState(() {
          _statusText = '等待说话';
        });
      }
    } else if (type == 'llm') {
      final text = message['text'] ?? '';
      if (text.isNotEmpty) {
        print('[VoiceCallScreen] ← LLM: $text');
      }
    }
  }

  /// 添加消息到会话
  void _addMessage(String text, MessageRole role) {
    Provider.of<ConversationProvider>(context, listen: false).addMessage(
      conversationId: widget.conversation.id,
      role: role,
      content: text,
    );
  }

  @override
  void dispose() {
    print('[VoiceCallScreen] dispose: 发送 abort + 断开连接');
    // 发送 abort + 断开连接
    _xiaozhiService.sendAbortMessage();
    _xiaozhiService.disconnectVoiceCall();
    _callTimer?.cancel();
    _audioVisualizerTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _connectToVoiceService() async {
    setState(() {
      _statusText = '正在连接...';
    });

    try {
      // ★ 关键：调用 connectVoiceCall() 建立 WebSocket 连接 + 初始化音频
      // （原来的 switchToVoiceCallMode() 只初始化了音频，从未建立 WebSocket 连接）
      await _xiaozhiService.connectVoiceCall();

      setState(() {
        _isConnected = true;
        _statusText = '已连接，等待 hello...';
      });

      if (mounted) {
        _showCustomSnackbar(
          message: 'WebSocket 已连接，等待服务器 hello...',
          icon: Icons.check_circle,
          iconColor: Colors.greenAccent,
        );
      }

      _startCallTimer();

      Provider.of<ConversationProvider>(context, listen: false).addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: '语音通话已开始',
      );

      // ★ 不再直接调用 _startSpeaking()！
      // 录音会在 xiaozhi_service 收到 hello 后自动开始
      print('[VoiceCallScreen] 连接完成，等待 hello 后自动开始录音...');
    } catch (e) {
      setState(() {
        _statusText = '连接失败';
        _isConnected = false;
      });
      print('[VoiceCallScreen] 连接失败: $e');

      if (mounted) {
        _showCustomSnackbar(
          message: '连接失败: $e',
          icon: Icons.error_outline,
          iconColor: Colors.redAccent,
        );
      }
    }
  }

  void _startCallTimer() {
    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _callDuration = Duration(seconds: timer.tick);
      });
    });
  }

  void _startAudioVisualizer() {
    _audioVisualizerTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (_isConnected) {
        setState(() {
          for (int i = 0; i < _audioLevels.length - 1; i++) {
            _audioLevels[i] = _audioLevels[i + 1];
          }

          final state = _xiaozhiService.voiceCallState;
          if (state == VoiceCallState.userSpeaking) {
            // 用户说话 - 高振幅
            _audioLevels[_audioLevels.length - 1] =
                0.05 + (0.6 * (0.5 + 0.5 * _animationController.value));
          } else if (state == VoiceCallState.aiSpeaking) {
            // AI 回复 - 中振幅
            _audioLevels[_audioLevels.length - 1] =
                0.05 + (0.4 * (0.5 + 0.5 * _animationController.value));
          } else {
            // 空闲 - 低振幅
            _audioLevels[_audioLevels.length - 1] =
                0.05 + (0.1 * (0.5 + 0.5 * _animationController.value));
          }
        });
      }
    });
  }

  // 发送打断消息
  void _sendAbortMessage() {
    // 发送打断消息
    _xiaozhiService.sendAbortMessage();

    if (mounted) {
      _showCustomSnackbar(
        message: '已发送打断信号',
        icon: Icons.pan_tool,
        iconColor: Colors.orangeAccent,
      );
    }
  }

  /// 根据状态机获取状态文字
  String _getStatusLabel() {
    final state = _xiaozhiService.voiceCallState;
    switch (state) {
      case VoiceCallState.idle:
        return '等待说话';
      case VoiceCallState.userSpeaking:
        return '正在录音';
      case VoiceCallState.aiSpeaking:
        return 'AI 回复中';
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    // 确保状态栏设置正确
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      extendBody: true,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        leading: Container(
          margin: const EdgeInsets.only(left: 8, top: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 24),
            onPressed: () {
              // 返回前发送 abort 并断开连接
              _xiaozhiService.sendAbortMessage();
              _xiaozhiService.disconnectVoiceCall();
              Navigator.pop(context);
            },
          ),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 渐变背景
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.primary.withOpacity(0.8),
                  Theme.of(context).colorScheme.primary.withOpacity(0.6),
                ],
              ),
            ),
          ),

          // 水波纹背景
          Positioned.fill(
            child: Opacity(
              opacity: 0.1,
              child: Image.asset(
                'assets/images/wave_pattern.png',
                fit: BoxFit.cover,
              ),
            ),
          ),

          // 主要内容
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 圆形头像
                Hero(
                  tag: 'avatar_${widget.conversation.id}',
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 15,
                          spreadRadius: 2,
                        ),
                      ],
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Theme.of(
                            context,
                          ).colorScheme.primary.withOpacity(0.9),
                          Theme.of(context).colorScheme.primaryContainer,
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // 名称显示
                Text(
                  widget.conversation.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                // 状态显示 - 使用拟物化样式
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _isConnected
                            ? Colors.green.withOpacity(0.2)
                            : Colors.red.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color:
                          _isConnected
                              ? Colors.green.withOpacity(0.6)
                              : Colors.red.withOpacity(0.6),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            _isConnected
                                ? Colors.green.withOpacity(0.2)
                                : Colors.red.withOpacity(0.2),
                        blurRadius: 8,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isConnected ? Icons.check_circle : Icons.error_outline,
                        color: _isConnected ? Colors.green : Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _getStatusLabel(),
                        style: TextStyle(
                          color: _isConnected ? Colors.green : Colors.red,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // 通话时长
                Text(
                  '通话时长: ${_formatDuration(_callDuration)}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 40),

                // 音频可视化
                _buildAudioVisualizer(),
                const SizedBox(height: 60),

                // 通话控制按钮
                Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom + 20,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildEndCallButton(),
                      const SizedBox(width: 40),
                      _buildControlButton(
                        icon: Icons.pan_tool, // 改为手掌图标表示打断
                        color: Colors.white,
                        backgroundColor: Colors.orange,
                        onPressed: _sendAbortMessage,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioVisualizer() {
    return Container(
      width: 240,
      height: 100,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.2),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: 0,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(
          _audioLevels.length,
          (index) => AnimatedContainer(
            duration: const Duration(milliseconds: 50),
            curve: Curves.easeInOut,
            width: 4,
            height: 80 * _audioLevels[index],
            decoration: BoxDecoration(
              color: _getBarColor(index, _audioLevels[index]),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Color _getBarColor(int index, double level) {
    final state = _xiaozhiService.voiceCallState;
    if (state == VoiceCallState.userSpeaking) {
      // 渐变从蓝色到绿色
      double position = index / _audioLevels.length;
      return Color.lerp(
        Colors.blue.shade400,
        Colors.green.shade400,
        position,
      )!.withOpacity(0.7 + 0.3 * level);
    } else {
      // 非说话状态时使用柔和的蓝色
      return Colors.blue.shade200.withOpacity(0.3 + 0.4 * level);
    }
  }

  Widget _buildControlButton({
    required IconData icon,
    required Color color,
    required Color backgroundColor,
    double size = 56,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: backgroundColor.withOpacity(0.4),
            blurRadius: 12,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Center(child: Icon(icon, color: color, size: size * 0.45)),
        ),
      ),
    );
  }

  Widget _buildEndCallButton() {
    return GestureDetector(
      onTap: () async {
        // 先发送打断消息
        await _xiaozhiService.sendAbortMessage();
        // 然后返回上一级页面
        Navigator.pop(context);
      },
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.red.shade400.withOpacity(0.3),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.call_end_rounded,
          color: Colors.white,
          size: 32,
        ),
      ),
    );
  }

  // 显示自定义Snackbar
  void _showCustomSnackbar({
    required String message,
    required IconData icon,
    required Color iconColor,
  }) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final snackBar = SnackBar(
      content: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.black87,
      duration: const Duration(seconds: 3),
      margin: EdgeInsets.only(
        bottom: MediaQuery.of(context).size.height - 120,
        left: 16,
        right: 16,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
    );

    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }
}
