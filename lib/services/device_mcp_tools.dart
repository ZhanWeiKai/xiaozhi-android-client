import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';

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

/// 拍照工具：程序化拍一张并保存到相册（不弹相机 UI）
class TakePhotoTool extends McpTool {
  final MethodChannel channel;
  TakePhotoTool(this.channel);

  @override
  String get name => 'phone.take_photo';

  @override
  String get description =>
      '使用手机的摄像头拍一张照片并自动保存到相册（无需用户手动按快门）。'
      '可选参数 camera 指定使用后置(back)或前置(front)摄像头，默认 back。'
      '用于用户说"帮我拍张照片 / 照一张 / 用前置拍一张"等场景。';

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
      } finally {
        await controller.dispose();
      }

      // 4. 存到相册（MediaStore DCIM/Camera，经 MethodChannel 由原生侧写入）
      final fileName = 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg';
      String savedUri;
      try {
        final res = await channel.invokeMethod('saveImageToGallery', {
          'path': xfile.path,
          'name': fileName,
        });
        savedUri = (res is Map && res['uri'] != null) ? res['uri'].toString() : fileName;
      } catch (e) {
        return McpToolResult(false, '已拍照，但保存到相册失败: $e');
      }
      // 清理临时文件
      try {
        await File(xfile.path).delete();
      } catch (_) {}

      return McpToolResult(true, '已用${useFront ? '前置' : '后置'}摄像头拍照并保存到相册：$fileName（$savedUri）');
    } catch (e) {
      return McpToolResult(false, '拍照失败：$e');
    }
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
      '二者二选一。可选 label 备注（显示在闹钟里）。';

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
      whenDesc = '${minutes}分钟后（${_hhmm(hour, minute)}）';
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
      final labelPart = label.isEmpty ? '' : '（$label）';
      return McpToolResult(
        true,
        '已设置系统闹钟$labelPart：$whenDesc，到点按系统闹钟响铃。可在手机时钟 App 里查看/修改。',
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
