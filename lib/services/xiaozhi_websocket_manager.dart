import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/io.dart'
    if (dart.library.html) 'package:web_socket_channel/html.dart';

/// 小智WebSocket事件类型
enum XiaozhiEventType { connected, disconnected, message, error, binaryMessage, firmwareUpdate }

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

  // 自建 Worker 模式：模型固定（对齐 simulate.html）；语言由配置传入
  static const String WORKER_MODEL = 'floki';
  // 自建 Worker OTA 版本路由：指向部署中的目标版本（0% traffic，header 路由）
  static const String WORKER_VERSION_OVERRIDE = 'xiaozhi-dev-2="e6a0e360-ddaf-4cf4-95df-327b03dbcf98"';

  WebSocketChannel? _channel;
  String? _wsUrl;
  String? _deviceId;
  String? _token;
  String? _otaUrl;
  String? _clientId;
  String _configType; // "official" / "custom" / "worker"
  String _lang; // 设备语言（自建 Worker：OTA Accept-Language + WS lang 参数）
  String _firmwareVersion; // 设备当前固件版本（'-1'=未安装哨兵），OTA body 上报此版本
  String? _pendingFwUrl; // OTA 响应里 worker 下发的固件下载地址（待自动下载）
  String? _pendingFwVer; // OTA 响应里 worker 下发的目标固件版本

  final List<XiaozhiWebSocketListener> _listeners = [];
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer; // 每 30s 发心跳，防空闲被服务端/代理断开
  StreamSubscription? _streamSubscription;

  /// 构造函数
  /// configType: "official" = 官方 xiaozhi.me (hardcoded WS_URL + headers auth)
  ///             "custom"  = 自定义 server (WS_URL from OTA + query params auth)
  ///             "worker"  = 自建 Worker (同 custom，但 query 加 dm+lang、hello 加 features.mcp)
  XiaozhiWebSocketManager({
    required String deviceId,
    required String otaUrl,
    required String clientId,
    required String wsUrl,
    String configType = 'official',
    String lang = 'zh-CN',
    String firmwareVersion = '-1',
  }) : _deviceId = deviceId,
      _otaUrl = otaUrl,
      _clientId = clientId,
      _wsUrl = wsUrl,
      _configType = configType,
      _lang = lang,
      _firmwareVersion = firmwareVersion {
    print('[connect-xiaozhi] WebSocketManager 创建: configType=$configType, wsUrl=$wsUrl, otaUrl=$otaUrl, deviceId=$deviceId, clientId=$clientId, lang=$lang');
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
      // 自建 Worker：OTA 需要带 dm、Accept-Language（对齐 simulate.html）
      // 版本路由：Cloudflare-Workers-Version-Overrides 将请求路由到指定的已部署版本
      if (_configType == 'worker') {
        request.headers.set('dm', WORKER_MODEL);
        request.headers.set('Accept-Language', _lang);
        request.headers.set('Cloudflare-Workers-Version-Overrides', WORKER_VERSION_OVERRIDE);
      }
      request.write(jsonEncode({
        'version': 2,
        'flash_size': 16777216,
        'psram_size': 0,
        'minimum_free_heap_size': 8318916,
        'mac_address': _deviceId,
        'device_id': _deviceId,  // Worker OTA 接口要求此字段
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
          'version': _firmwareVersion,
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

      // 自建 Worker：解析 worker 下发的固件升级信息 firmware{version,url}
      String? fwVer;
      String? fwUrl;
      if (_configType == 'worker') {
        final fw = data['firmware'];
        if (fw is Map) {
          fwVer = fw['version']?.toString();
          fwUrl = fw['url']?.toString();
          if (fwUrl != null && fwUrl.isNotEmpty) {
            _pendingFwVer = fwVer;
            _pendingFwUrl = fwUrl;
            print('[connect-xiaozhi] ▲ OTA 固件升级可用: v$fwVer ($fwUrl)');
          } else {
            print('[connect-xiaozhi] OTA: 已是最新 (v$_firmwareVersion)');
          }
        }
      }

      print('[connect-xiaozhi] ✓ OTA 注册成功');
      print('[connect-xiaozhi]   Token: ${token.length > 16 ? token.substring(0, 16) : token}...');
      if (otaWsUrl != null && otaWsUrl.isNotEmpty) {
        print('[connect-xiaozhi]   OTA WebSocket URL: $otaWsUrl');
      }

      return {
        'token': token,
        if (otaWsUrl != null && otaWsUrl.isNotEmpty) 'wsUrl': otaWsUrl,
        if (fwVer != null) 'firmwareVersion': fwVer,
        if (fwUrl != null) 'firmwareUrl': fwUrl,
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

      if (_configType == 'custom' || _configType == 'worker') {
        // ===== 自定义 server / 自建 worker 模式 =====
        // WS_URL 从 OTA 响应获取，认证通过 URL query params 传递
        final otaWsUrl = otaResult['wsUrl'];
        if (otaWsUrl == null || otaWsUrl.isEmpty) {
          throw Exception('${_configType == 'worker' ? '自建 worker' : '自定义 server'} OTA 未返回 websocket.url');
        }
        _wsUrl = otaWsUrl;

        // 构建带认证参数的 URL
        // custom: authorization/device-id/client-id（与 WebUI _build_ws_url 一致）
        // worker: headers 认证（dm + lang + Cloudflare-Workers-Version-Overrides）
        final fullUrl = _configType == 'worker'
            ? _buildWorkerWsUrl(_wsUrl!)
            : _buildAuthUrl(_wsUrl!, _token!, _deviceId!, _clientId!);

        if (_configType == 'worker') {
          // worker 模式：headers 认证 + 版本路由
          final headers = <String, String>{
            'Authorization': 'Bearer $_token',
            'Device-Id': _deviceId!,
            'Client-Id': _clientId!,
            'dm': WORKER_MODEL,
            'lang': _lang,
            'Cloudflare-Workers-Version-Overrides': WORKER_VERSION_OVERRIDE,
          };
          print('[connect-xiaozhi] 【步骤2-worker】开始连接 WebSocket (headers 认证 + 版本路由)...');
          print('[connect-xiaozhi] 目标: $fullUrl');
          _channel = IOWebSocketChannel.connect(Uri.parse(fullUrl), headers: headers);
        } else {
          print('[connect-xiaozhi] 【步骤2-$_configType】开始连接 WebSocket (query params 认证)...');
          print('[connect-xiaozhi] 目标: $fullUrl');
          _channel = IOWebSocketChannel.connect(Uri.parse(fullUrl));
        }
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

      // 启动心跳：每 30s 发一次 heartbeat，保持 WS 不被空闲断开（对齐 simulate.html）
      _startHeartbeat();

      // 4.5 自建 Worker：若 OTA 下发了固件 URL，自动下载（后台，不阻塞聊天）
      if (_configType == 'worker' && _pendingFwUrl != null && _pendingFwVer != null) {
        _autoDownloadFirmware(_pendingFwUrl!, _pendingFwVer!);
      }

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

  /// 自动下载 worker 下发的固件 bin（模拟 OTA：只存内存、报字节数，不真烧录）。
  /// 下载成功 → 派发 firmwareUpdate{state:done} 事件（上层据此 bump 版本 + 持久化 + 刷 UI）。
  /// 失败 → 派发 {state:error}，不 bump 版本。
  Future<void> _autoDownloadFirmware(String url, String newVersion) async {
    print('[connect-xiaozhi] 开始自动下载固件 v$newVersion: $url');
    _dispatchEvent(XiaozhiEvent(type: XiaozhiEventType.firmwareUpdate, data: {
      'state': 'downloading',
      'from': _firmwareVersion,
      'to': newVersion,
    }));
    try {
      final client = HttpClient();
      client.autoUncompress = true;
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final bytes = await resp.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      client.close();
      final kb = (bytes.length / 1024).toStringAsFixed(1);
      print('[connect-xiaozhi] ▲ 固件下载完成: ${bytes.length} bytes (${kb} KB)，模拟烧录(不写分区)');
      final oldVer = _firmwareVersion;
      _firmwareVersion = newVersion; // bump 上报版本，下次 OTA 匹配不再下发
      _pendingFwUrl = null;
      _pendingFwVer = null;
      _dispatchEvent(XiaozhiEvent(type: XiaozhiEventType.firmwareUpdate, data: {
        'state': 'done',
        'from': oldVer,
        'to': newVersion,
        'bytes': bytes.length,
      }));
    } catch (e) {
      print('[connect-xiaozhi] ✗ 固件下载失败: $e');
      _dispatchEvent(XiaozhiEvent(type: XiaozhiEventType.firmwareUpdate, data: {
        'state': 'error',
        'to': newVersion,
        'error': e.toString(),
      }));
    }
  }

  /// 构建带认证参数的 WebSocket URL（自定义 server 使用，与 WebUI _build_ws_url 一致）
  String _buildAuthUrl(String baseUrl, String token, String deviceId, String clientId) {
    final separator = baseUrl.contains('?') ? '&' : '?';
    return '$baseUrl${separator}authorization=Bearer%20$token&device-id=$deviceId&client-id=$clientId';
  }

  /// 构建自建 Worker 的 WebSocket URL（不含认证参数，认证走 headers）
  String _buildWorkerWsUrl(String baseUrl) {
    return baseUrl;
  }

  /// 断开WebSocket连接
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    await _streamSubscription?.cancel();
    _streamSubscription = null;

    if (_channel != null) {
      await _channel!.sink.close(status.normalClosure);
      _channel = null;
      print('$TAG: 连接已断开');
    }
  }

  /// 启动心跳：每 30s 发一次 heartbeat，防止 WS 空闲被服务端/代理断开（对齐 simulate.html）。
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_channel != null && isConnected) {
        sendMessage(jsonEncode({'type': 'heartbeat'}));
      }
    });
  }

  /// 发送 Hello 消息
  /// 官方模式: 简单 hello (version 3, audio_params)
  /// 自定义模式: hello 包含 device_id, device_name, device_mac, token（与 WebUI handle_client_messages 一致）
  void _sendHelloMessage() {
    Map<String, dynamic> hello;

    if (_configType == 'worker') {
      // 自建 Worker hello：同 custom + features.mcp:true（声明 MCP 支持，触发上游 MCP 握手）
      hello = {
        "type": "hello",
        "version": 3,
        "features": {"mcp": true},
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
      print('[connect-xiaozhi] 【步骤3-worker】发送 hello 消息 (含 features.mcp/device_id/device_mac/token): ${jsonEncode(hello)}');
    } else if (_configType == 'custom') {
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
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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
