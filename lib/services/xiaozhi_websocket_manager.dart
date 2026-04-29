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

  final List<XiaozhiWebSocketListener> _listeners = [];
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  StreamSubscription? _streamSubscription;

  /// 构造函数（与官方 WebUI 保持一致：wsUrl 和 otaUrl 都是从配置中 hardcode 的）
  XiaozhiWebSocketManager({
    required String deviceId,
    required String otaUrl,
    required String clientId,
    required String wsUrl,
  }) : _deviceId = deviceId,
      _otaUrl = otaUrl,
      _clientId = clientId,
      _wsUrl = wsUrl {
    print('[connect-xiaozhi] WebSocketManager 创建: wsUrl=$wsUrl, otaUrl=$otaUrl, deviceId=$deviceId, clientId=$clientId');
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

  /// 调用 OTA 接口注册设备并获取 Token（与官方 WebUI _update_ota_address 一致）
  Future<String> _registerDevice() async {
    print('[connect-xiaozhi] 【步骤1】开始 OTA 注册设备...');
    print('[connect-xiaozhi] OTA URL: $_otaUrl');
    print('[connect-xiaozhi] Device-Id: $_deviceId');
    print('[connect-xiaozhi] Client-Id: $_clientId');

    try {
      final uri = Uri.parse(_otaUrl!);
      final client = HttpClient();
      final request = await client.postUrl(uri);
      request.headers.set('Device-Id', _deviceId!);
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

      // 获取 websocket token（用于后续 WebSocket 认证）
      final websocket = data['websocket'];
      if (websocket == null) {
        print('[connect-xiaozhi] ✗ OTA 返回数据缺少 websocket 字段，响应 keys: ${data.keys.toList()}');
        throw Exception('OTA 返回数据格式错误: 缺少 websocket 字段');
      }

      final token = websocket['token'] as String;
      print('[connect-xiaozhi] ✓ OTA 注册成功，Token: ${token.length > 16 ? token.substring(0, 16) : token}...');

      return token;
    } catch (e) {
      print('[connect-xiaozhi] ✗ OTA 注册异常: $e');
      rethrow;
    }
  }

  /// 连接到WebSocket服务器（与官方 WebUI 保持一致的流程）
  Future<void> connect() async {
    try {
      print('[connect-xiaozhi] ========== 开始连接流程 ==========');
      print('[connect-xiaozhi] WS URL: $_wsUrl');
      print('[connect-xiaozhi] OTA URL: $_otaUrl');
      print('[connect-xiaozhi] Device-Id: $_deviceId');
      print('[connect-xiaozhi] Client-Id: $_clientId');

      // 1. 调用 OTA 注册设备并获取 Token（与 WebUI _update_ota_address 一致）
      final token = await _registerDevice();
      _token = token;

      // 2. 如果已连接，先断开
      if (_channel != null) {
        await disconnect();
      }

      // 3. 构造 headers（与 WebUI additional_headers 一致）
      final headers = <String, String>{
        'Device-Id': _deviceId!,
        'Client-Id': _clientId!,
        'Protocol-Version': '1',
        'Authorization': 'Bearer $token',
      };

      print('[connect-xiaozhi] 【步骤2】开始连接 WebSocket...');
      print('[connect-xiaozhi] 目标: $_wsUrl');
      print('[connect-xiaozhi] Headers: Device-Id=$_deviceId, Client-Id=$_clientId, Protocol-Version=1, Authorization=Bearer ${token.length > 16 ? token.substring(0, 16) : token}...');

      // 4. 使用 IOWebSocketChannel 连接（认证信息通过 headers 传递，与 WebUI 一致）
      _channel = IOWebSocketChannel.connect(
        Uri.parse(_wsUrl!),
        headers: headers,
      );

      print('[connect-xiaozhi] ✓ WebSocket 连接已建立');

      // 5. 监听 WebSocket 事件
      _streamSubscription = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: _onError,
        cancelOnError: false,
      );

      // 6. 连接成功
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.connected, data: null),
      );

      // 7. 发送 hello 消息
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

  /// 发送 Hello 消息（与官方 WebUI 保持一致）
  void _sendHelloMessage() {
    final hello = {
      "type": "hello",
      "version": 3,
      "audio_params": {
        "format": "opus",
        "sample_rate": 16000,
        "channels": 1,
        "frame_duration": 60,
      },
    };
    print('[connect-xiaozhi] 【步骤3】发送 hello 消息: ${jsonEncode(hello)}');
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
