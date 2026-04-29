import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/io.dart'
    if (dart.library.html) 'package:web_socket_channel/html.dart';

/// 小智WebSocket事件类型
enum XiaozhiEventType { connected, disconnected, message, error, binaryMessage }

/// 小智WebSocket事件
class XiaozhiEvent {
  final XiaozhiEventType type;
  final dynamic data;

  XiaozhiEvent({required this.type, this.data});
}

/// 小智WebSocket监听器接口
typedef XiaozhiWebSocketListener = void Function(XiaozhiEvent event);

/// 小智WebSocket管理器
class XiaozhiWebSocketManager {
  static const String TAG = "XiaozhiWebSocket";
  static const int RECONNECT_DELAY = 3000;

  WebSocketChannel? _channel;
  String? _wsUrl;
  String? _deviceId;
  String? _token;
  String? _otaUrl;
  String? _clientId;
  String _configType; // "official" 或 "custom"

  final List<XiaozhiWebSocketListener> _listeners = [];
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  StreamSubscription? _streamSubscription;

  /// 构造函数
  /// configType: "official" = 官方 xiaozhi.me (hardcoded WS_URL + headers auth)
  ///             "custom" = 自定义 server (WS_URL from OTA + query params auth)
  XiaozhiWebSocketManager({
    required String deviceId,
    required String otaUrl,
    required String clientId,
    required String wsUrl,
    String configType = 'official',
  }) : _deviceId = deviceId,
      _otaUrl = otaUrl,
      _clientId = clientId,
      _wsUrl = wsUrl,
      _configType = configType {
    print('[connect-xiaozhi] WebSocketManager 创建: configType=$configType, wsUrl=$wsUrl, otaUrl=$otaUrl, deviceId=$deviceId, clientId=$clientId');
  }

  /// 添加事件监听器
  void addListener(XiaozhiWebSocketListener listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// 移除事件监听器
  void removeListener(XiaozhiWebSocketListener listener) {
    _listeners.remove(listener);
  }

  /// 分发事件到所有监听器
  void _dispatchEvent(XiaozhiEvent event) {
    for (var listener in _listeners) {
      listener(event);
    }
  }

  /// 调用 OTA 接口注册设备并获取 Token 和 WebSocket URL（与官方 WebUI _update_ota_address 一致）
  /// 返回 Map 包含 'token' 和可选的 'wsUrl'（自定义 server 从 OTA 获取）
  Future<Map<String, String>> _registerDevice() async {
    print('[connect-xiaozhi] 【步骤1】开始 OTA 注册设备... (configType=$_configType)');
    print('[connect-xiaozhi] OTA URL: $_otaUrl');
    print('[connect-xiaozhi] Device-Id: $_deviceId');
    print('[connect-xiaozhi] Client-Id: $_clientId');

    try {
      final uri = Uri.parse(_otaUrl!);
      final client = HttpClient();
      // 自动跟随重定向（Python requests 默认跟随 301/302，Dart HttpClient 默认不跟随）
      client.autoUncompress = true;
      final request = await client.postUrl(uri);
      // 允许重定向（POST 请求遇到 301/302 时跟随跳转）
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set('Device-Id', _deviceId!);
      request.headers.set('Client-Id', _clientId!);
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({
        'version': 2,
        'flash_size': 16777216,
        'psram_size': 0,
        'minimum_free_heap_size': 8318916,
        'mac_address': _deviceId,
        'uuid': _clientId,
        'chip_model_name': 'esp32s3',
        'chip_info': {
          'model': 9,
          'cores': 2,
          'revision': 2,
          'features': 18,
        },
        'application': {
          'name': 'xiaozhi',
          'version': '1.1.2',
          'idf_version': 'v5.3.2-dirty',
        },
        'partition_table': [],
        'ota': {'label': 'factory'},
        'board': {
          'type': 'bread-compact-wifi',
          'ip': '',
          'mac': _deviceId,
        },
      }));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      client.close();

      print('[connect-xiaozhi] OTA HTTP 状态码: ${response.statusCode}');
      print('[connect-xiaozhi] OTA 响应 body: $responseBody');

      if (response.statusCode != 200) {
        print('[connect-xiaozhi] ✗ OTA 请求失败: HTTP ${response.statusCode}');
        throw Exception('OTA 请求失败: HTTP ${response.statusCode}');
      }

      final data = jsonDecode(responseBody);

      // 获取 websocket 信息
      final websocket = data['websocket'];
      if (websocket == null) {
        print('[connect-xiaozhi] ✗ OTA 返回数据缺少 websocket 字段，响应 keys: ${data.keys.toList()}');
        throw Exception('OTA 返回数据格式错误: 缺少 websocket 字段');
      }

      final token = websocket['token'] as String;
      final otaWsUrl = websocket['url'] as String?;

      print('[connect-xiaozhi] ✓ OTA 注册成功');
      print('[connect-xiaozhi]   Token: ${token.length > 16 ? token.substring(0, 16) : token}...');
      if (otaWsUrl != null && otaWsUrl.isNotEmpty) {
        print('[connect-xiaozhi]   OTA WebSocket URL: $otaWsUrl');
      }

      return {
        'token': token,
        if (otaWsUrl != null && otaWsUrl.isNotEmpty) 'wsUrl': otaWsUrl,
      };
    } catch (e) {
      print('[connect-xiaozhi] ✗ OTA 注册异常: $e');
      rethrow;
    }
  }

  /// 连接到WebSocket服务器（支持官方和自定义两种模式）
  Future<void> connect() async {
    try {
      print('[connect-xiaozhi] ========== 开始连接流程 (configType=$_configType) ==========');
      print('[connect-xiaozhi] WS URL: $_wsUrl');
      print('[connect-xiaozhi] OTA URL: $_otaUrl');
      print('[connect-xiaozhi] Device-Id: $_deviceId');
      print('[connect-xiaozhi] Client-Id: $_clientId');

      // 1. 调用 OTA 注册设备并获取 Token 和（可能有的）WebSocket URL
      final otaResult = await _registerDevice();
      _token = otaResult['token']!;

      // 2. 如果已连接，先断开
      if (_channel != null) {
        await disconnect();
      }

      if (_configType == 'custom') {
        // ===== 自定义 server 模式 =====
        // WS_URL 从 OTA 响应获取，认证通过 URL query params 传递
        final otaWsUrl = otaResult['wsUrl'];
        if (otaWsUrl == null || otaWsUrl.isEmpty) {
          throw Exception('自定义 server OTA 未返回 websocket.url');
        }
        _wsUrl = otaWsUrl;

        // 构建带认证参数的 URL（与 WebUI _build_ws_url 一致）
        final fullUrl = _buildAuthUrl(_wsUrl!, _token!, _deviceId!, _clientId!);

        print('[connect-xiaozhi] 【步骤2-custom】开始连接 WebSocket (query params 认证)...');
        print('[connect-xiaozhi] 目标: $fullUrl');

        _channel = IOWebSocketChannel.connect(Uri.parse(fullUrl));
      } else {
        // ===== 官方 xiaozhi.me 模式 =====
        // WS_URL 硬编码，认证通过 headers 传递
        final headers = <String, String>{
          'Device-Id': _deviceId!,
          'Client-Id': _clientId!,
          'Protocol-Version': '1',
          'Authorization': 'Bearer $_token',
        };

        print('[connect-xiaozhi] 【步骤2-official】开始连接 WebSocket (headers 认证)...');
        print('[connect-xiaozhi] 目标: $_wsUrl');
        print('[connect-xiaozhi] Headers: Device-Id=$_deviceId, Client-Id=$_clientId, Protocol-Version=1, Authorization=Bearer ${_token!.length > 16 ? _token!.substring(0, 16) : _token}...');

        _channel = IOWebSocketChannel.connect(
          Uri.parse(_wsUrl!),
          headers: headers,
        );
      }

      print('[connect-xiaozhi] ✓ WebSocket 连接已建立');

      // 3. 监听 WebSocket 事件
      _streamSubscription = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: _onError,
        cancelOnError: false,
      );

      // 4. 连接成功
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.connected, data: null),
      );

      // 5. 发送 hello 消息（官方和自定义的 hello 内容不同）
      Timer(const Duration(milliseconds: 200), () {
        _sendHelloMessage();
      });
    } catch (e) {
      print('[connect-xiaozhi] ✗ 连接流程失败: $e');
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.error, data: "连接失败: $e"),
      );
    }
  }

  /// 构建带认证参数的 WebSocket URL（自定义 server 使用，与 WebUI _build_ws_url 一致）
  String _buildAuthUrl(String baseUrl, String token, String deviceId, String clientId) {
    final separator = baseUrl.contains('?') ? '&' : '?';
    return '$baseUrl${separator}authorization=Bearer%20$token&device-id=$deviceId&client-id=$clientId';
  }

  /// 断开WebSocket连接
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _isReconnecting = false;

    await _streamSubscription?.cancel();
    _streamSubscription = null;

    if (_channel != null) {
      await _channel!.sink.close(status.normalClosure);
      _channel = null;
      print('$TAG: 连接已断开');
    }
  }

  /// 发送 Hello 消息
  /// 官方模式: 简单 hello (version 3, audio_params)
  /// 自定义模式: hello 包含 device_id, device_name, device_mac, token（与 WebUI handle_client_messages 一致）
  void _sendHelloMessage() {
    Map<String, dynamic> hello;

    if (_configType == 'custom') {
      // 自定义 server hello：注入认证信息（与 WebUI handle_client_messages 中的注入逻辑一致）
      hello = {
        "type": "hello",
        "version": 3,
        "audio_params": {
          "format": "opus",
          "sample_rate": 16000,
          "channels": 1,
          "frame_duration": 60,
        },
        "device_id": _deviceId,
        "device_name": "xiaozhi-android",
        "device_mac": _deviceId,
        "token": _token,
      };
      print('[connect-xiaozhi] 【步骤3-custom】发送 hello 消息 (含 device_id/device_mac/token): ${jsonEncode(hello)}');
    } else {
      // 官方 xiaozhi.me hello：简单格式
      hello = {
        "type": "hello",
        "version": 3,
        "audio_params": {
          "format": "opus",
          "sample_rate": 16000,
          "channels": 1,
          "frame_duration": 60,
        },
      };
      print('[connect-xiaozhi] 【步骤3-official】发送 hello 消息: ${jsonEncode(hello)}');
    }

    sendMessage(jsonEncode(hello));
  }

  /// 发送文本消息
  void sendMessage(String message) {
    if (_channel != null && isConnected) {
      _channel!.sink.add(message);
    } else {
      print('$TAG: 发送失败，连接未建立');
    }
  }

  /// 发送二进制数据
  void sendBinaryMessage(List<int> data) {
    if (_channel != null && isConnected) {
      try {
        _channel!.sink.add(data);
      } catch (e) {
        print('$TAG: 二进制数据发送失败: $e');
      }
    } else {
      print('$TAG: 发送失败，连接未建立');
    }
  }

  /// 发送文本请求
  void sendTextRequest(String text) {
    if (!isConnected) {
      print('$TAG: 发送失败，连接未建立');
      return;
    }

    try {
      final jsonMessage = {
        "type": "listen",
        "state": "detect",
        "text": text,
        "source": "text",
      };

      print('$TAG: 发送文本请求: ${jsonEncode(jsonMessage)}');
      sendMessage(jsonEncode(jsonMessage));
    } catch (e) {
      print('$TAG: 发送文本请求失败: $e');
    }
  }

  /// 处理收到的消息
  void _onMessage(dynamic message) {
    if (message is String) {
      print('[connect-xiaozhi] ← 收到文本消息: $message');
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.message, data: message),
      );
    } else if (message is List<int>) {
      print('[connect-xiaozhi] ← 收到二进制消息: ${message.length} bytes');
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.binaryMessage, data: message),
      );
    }
  }

  /// 处理断开连接事件
  void _onDisconnected() {
    print('[connect-xiaozhi] ✗ WebSocket 连接已断开');
    _dispatchEvent(
      XiaozhiEvent(type: XiaozhiEventType.disconnected, data: null),
    );

    // 尝试自动重连
    if (!_isReconnecting && _otaUrl != null) {
      _isReconnecting = true;
      _reconnectTimer = Timer(
        const Duration(milliseconds: RECONNECT_DELAY),
        () {
          _isReconnecting = false;
          connect();
        },
      );
    }
  }

  /// 处理错误事件
  void _onError(error) {
    print('[connect-xiaozhi] ✗ WebSocket 错误: $error');
    _dispatchEvent(
      XiaozhiEvent(type: XiaozhiEventType.error, data: error.toString()),
    );
  }

  /// 判断是否已连接
  bool get isConnected {
    return _channel != null && _streamSubscription != null;
  }
}
