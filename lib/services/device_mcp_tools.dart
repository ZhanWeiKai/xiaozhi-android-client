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

/// 设备 MCP 工具注册表
class DeviceMcpTools {
  static const MethodChannel channel = MethodChannel('device.mcp.tools');

  final List<McpTool> _tools = [];

  DeviceMcpTools() {
    _register(TakePhotoTool(channel));
    // 后续工具在此注册（阶段二/三）：
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
