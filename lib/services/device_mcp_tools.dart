import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';
import '../providers/config_provider.dart';

/// 设备侧 MCP 工具：把手机能力暴露给 xiaozhi 服务端的 LLM 调用。
/// 详见 mydocs/device-mcp-tools-plan.md

/// MCP 工具执行结果
class McpToolResult {
  final bool success;
  final String text;
  McpToolResult(this.success, this.text);
}

/// 一个 MCP 工具的抽象
abstract class McpTool {
  String get name; // 工具名（给 LLM 调用）
  String get description; // 给 LLM 看的说明（决定 LLM 何时触发）
  Map<String, dynamic> get inputSchema; // 参数 JSON Schema
  Future<McpToolResult> call(Map<String, dynamic> arguments); // 执行
}

/// 拍照工具：程序化拍一张，直接调视觉模型理解画面（不保存本地相册，不弹相机 UI）
/// 详见 mydocs/device-mcp-photo-vision-implementation-plan.md
class TakePhotoTool extends McpTool {
  final MethodChannel channel;
  TakePhotoTool(this.channel);

  @override
  String get name => 'phone.take_photo';

  @override
  String get description =>
      '使用手机摄像头拍一张照片，不保存到本地相册，而是直接调用视觉模型理解画面并返回图片内容描述。'
      '可选参数 camera 指定使用后置(back)或前置(front)摄像头，默认 back。'
      '用于用户说"帮我拍张照片看看 / 看看这是什么 / 识别一下画面 / 用前置看看我"等场景。';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'camera': {
        'type': 'string',
        'enum': ['back', 'front'],
        'default': 'back',
        'description': '使用哪个摄像头：back=后置，front=前置',
      },
    },
    'required': <String>[],
  };

  @override
  Future<McpToolResult> call(Map<String, dynamic> arguments) async {
    final useFront = arguments['camera'] == 'front';
    String? tempPath;

    try {
      // 1. 相机权限
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        return McpToolResult(false, '没有相机权限，无法拍照');
      }

      // 2. 选摄像头
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        return McpToolResult(false, '设备没有可用的摄像头');
      }
      final want = useFront ? CameraLensDirection.front : CameraLensDirection.back;
      CameraDescription? cam;
      for (final c in cameras) {
        if (c.lensDirection == want) {
          cam = c;
          break;
        }
      }
      cam ??= cameras.first;

      // 3. 初始化并拍照（无预览，程序化捕获）
      final controller = CameraController(
        cam,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      late final XFile xfile;
      try {
        await controller.initialize().timeout(const Duration(seconds: 6));
        // 给自动对焦/曝光一点时间
        await Future.delayed(const Duration(milliseconds: 700));
        xfile = await controller.takePicture().timeout(const Duration(seconds: 4));
        tempPath = xfile.path;
      } finally {
        await controller.dispose();
      }

      // 4. 设备侧直接调视觉模型（Anthropic 兼容 /v1/messages，不走 Worker/R2）
      try {
        final bytes = await File(xfile.path).readAsBytes();
        final b64 = base64Encode(bytes);

        final response = await http.post(
          Uri.parse('${ConfigProvider.VISION_API_BASE}/v1/messages'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${ConfigProvider.VISION_API_TOKEN}',
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': ConfigProvider.VISION_MODEL,
            'max_tokens': 1024,
            'messages': [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': 'image/jpeg',
                      'data': b64,
                    },
                  },
                  {
                    'type': 'text',
                    'text': '请描述这张照片里的内容。',
                  },
                ],
              },
            ],
          }),
        ).timeout(const Duration(seconds: 30));

        final parsed = _parseVisionResponse(response.statusCode, response.body);
        if (!parsed.success) {
          return parsed;
        }

        return McpToolResult(true, '图片视觉理解结果：${parsed.text}');
      } on TimeoutException {
        return McpToolResult(false, '拍照成功，但视觉模型响应超时，请稍后再试');
      } on SocketException catch (e) {
        return McpToolResult(false, '拍照成功，但调用视觉模型失败：${e.message}');
      } catch (e) {
        return McpToolResult(false, '拍照成功，但视觉理解失败：$e');
      }
    } catch (e) {
      return McpToolResult(false, '拍照失败：$e');
    } finally {
      // 清理临时文件（不管成功失败都不留存）
      final path = tempPath;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  /// 解析视觉模型响应：成功取 content 中第一个 text 块的 text。
  McpToolResult _parseVisionResponse(int statusCode, String body) {
    Map<String, dynamic>? json;
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          json = decoded;
        }
      } catch (_) {}
    }

    if (statusCode != 200) {
      // 代理/模型错误体：{"error":{"message":...}} 或 {"error":{"message":...,"type":...}}
      final err = json?['error'];
      final detail = (err is Map) ? (err['message']?.toString() ?? err['type']?.toString()) : null;
      if (statusCode == 401 || statusCode == 403) {
        return McpToolResult(false, '拍照成功，但视觉服务认证失败：${detail ?? 'HTTP $statusCode'}');
      }
      return McpToolResult(false, '拍照成功，但视觉服务返回异常：${detail ?? 'HTTP $statusCode'}');
    }

    if (json == null) {
      return McpToolResult(false, '拍照成功，但视觉服务响应格式异常');
    }

    // Anthropic Messages 响应：content 为 block 数组，取第一个 type==text 的 text
    final content = json['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          final text = block['text']?.toString().trim();
          if (text != null && text.isNotEmpty) {
            return McpToolResult(true, text);
          }
        }
      }
    }

    // 兼容 OpenAI 风格 choices[0].message.content（代理可能透传）
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final msg = choices[0] is Map ? choices[0]['message'] : null;
      final text = msg is Map ? msg['content']?.toString().trim() : null;
      if (text != null && text.isNotEmpty) {
        return McpToolResult(true, text);
      }
    }

    final errMsg = json['message']?.toString() ?? json['error']?.toString();
    return McpToolResult(false, '拍照成功，但视觉理解失败：${errMsg ?? '响应无可读文本'}');
  }
}

/// 闹钟工具：写入系统时钟 App（ACTION_SET_ALARM），真系统闹钟
class SetAlarmTool extends McpTool {
  final MethodChannel channel;
  SetAlarmTool(this.channel);

  @override
  String get name => 'phone.set_alarm';

  @override
  String get description =>
      '设置一个系统闹钟（写入手机时钟 App），到点按系统闹钟方式响铃'
      '（震动+铃声，锁屏/重启/App被杀都能响）。'
      '适合"帮我设 X 点的闹钟"或"X 分钟后提醒我"。'
      '参数 time=绝对时间 HH:MM（如 "19:00"），或 minutes=相对分钟数（如 5）。'
      '二者二选一。可选 label 备注（显示在闹钟里）。'
      '闹钟由系统时钟 App 托管，设置后无需保持本 App 运行，关闭也不影响响铃。';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'time': {
        'type': 'string',
        'description': '绝对时间 HH:MM（24h），如 "19:00"',
      },
      'minutes': {
        'type': 'number',
        'description': '相对分钟数（从现在起），如 5',
      },
      'label': {
        'type': 'string',
        'description': '闹钟备注/名称（可选，显示在时钟 App 里）',
      },
    },
    'required': <String>[],
  };

  @override
  Future<McpToolResult> call(Map<String, dynamic> arguments) async {
    final label = arguments['label']?.toString() ?? '';

    int? hour;
    int? minute;
    String whenDesc = '';

    // 相对分钟数 → 算成绝对 hour:minute（用设备本地时钟）
    final minutes = arguments['minutes'];
    if (minutes is num) {
      final target =
          DateTime.now().add(Duration(seconds: (minutes.toDouble() * 60).round()));
      hour = target.hour;
      minute = target.minute;
      whenDesc = '$minutes分钟后（${_hhmm(hour, minute)}）';
    }

    // 绝对时间 HH:MM
    final timeStr = arguments['time']?.toString();
    if (hour == null && timeStr != null && timeStr.isNotEmpty) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(timeStr.trim());
      if (m == null) {
        return McpToolResult(false, '时间格式无法解析：$timeStr（需要 HH:MM，如 19:00）');
      }
      final h = int.tryParse(m.group(1)!);
      final min = int.tryParse(m.group(2)!);
      if (h == null || min == null || h < 0 || h > 23 || min < 0 || min > 59) {
        return McpToolResult(false, '时间非法：$timeStr');
      }
      hour = h;
      minute = min;
      whenDesc = _hhmm(hour, minute);
    }

    if (hour == null || minute == null) {
      return McpToolResult(false, '请提供 time(HH:MM) 或 minutes 中的一个');
    }

    try {
      await channel.invokeMethod('setSystemAlarm', {
        'hour': hour,
        'minute': minute,
        'label': label,
      });
      return McpToolResult(
        true,
        '正在为你设置 $whenDesc 的系统闹钟。页面准备跳到时钟 App，需要你手动切回本 App（AI-LHHT）继续。'
        '闹钟由系统时钟 App 托管，到点会响铃，无需保持本 App 运行。可在时钟 App 查看/修改。',
      );
    } catch (e) {
      return McpToolResult(false, '设置系统闹钟失败：$e');
    }
  }

  String _hhmm(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// 设备 MCP 工具注册表
class DeviceMcpTools {
  static const MethodChannel channel = MethodChannel('device.mcp.tools');

  final List<McpTool> _tools = [];

  DeviceMcpTools() {
    _register(TakePhotoTool(channel));
    _register(SetAlarmTool(channel));
    // 后续工具在此注册（阶段三）：
    // _register(TorchTool());
    // _register(GetLocationTool());
  }

  void _register(McpTool tool) => _tools.add(tool);

  /// tools/list 响应需要的工具数组
  List<Map<String, dynamic>> toolsList() {
    return _tools
        .map((t) => {
              'name': t.name,
              'description': t.description,
              'inputSchema': t.inputSchema,
            })
        .toList();
  }

  /// tools/call 派发；返回 null 表示没有该工具（由调用方回 method not found）。
  /// self.camera.take_photo 别名到 phone.take_photo（Worker 会注入前者）。
  Future<McpToolResult?> call(String name, Map<String, dynamic> arguments) async {
    final alias = name == 'self.camera.take_photo' ? 'phone.take_photo' : name;
    for (final t in _tools) {
      if (t.name == alias) {
        return await t.call(arguments);
      }
    }
    return null;
  }

  bool hasTool(String name) {
    final alias = name == 'self.camera.take_photo' ? 'phone.take_photo' : name;
    return _tools.any((t) => t.name == alias);
  }
}
