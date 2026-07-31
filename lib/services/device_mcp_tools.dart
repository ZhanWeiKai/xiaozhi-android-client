import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
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
  final DeviceMcpTools _tools; // 读 macAddress 用于上传 worker（Device-Id）
  TakePhotoTool(this.channel, this._tools);

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

      // 4. 读 JPEG。两种触发：
      //    - worker 远程抓拍（arguments 带 question）：只拍照 + 上传 worker，跳过本地视觉（快、稳）。
      //    - LLM 语音触发：拍照 + 上传 worker + 跑本地视觉给 TTS。
      // 不管哪种，都先把 JPEG 上传给 worker（fire-and-forget，用内存 bytes，finally 删临时文件无竞态）。
      final bytes = await File(xfile.path).readAsBytes();
      if (_tools.macAddress.isNotEmpty) {
        // ignore: unawaited_futures
        _uploadToWorker(bytes, _tools.macAddress);
      }
      final isWorkerTrigger = arguments['question'] != null;
      if (isWorkerTrigger) {
        final kb = (bytes.length / 1024).toStringAsFixed(1);
        print('[xz_dbg] take_photo: worker 触发，跳过本地视觉，已拍照+上传 $kb KB');
        return McpToolResult(true, '已拍照并上传 worker（${kb} KB），未做本地视觉分析。');
      }

      // LLM 触发：设备侧直接调视觉模型（Anthropic 兼容 /v1/messages，不走 Worker/R2）
      try {
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

  /// 把 JPEG 上传给 worker /vision/explain（multipart，带 Device-Id + dm）。
  /// 这是给 worker 的副作用（worker 按设备做自己的视觉/R2 存档），best-effort：
  /// 不阻塞视觉、不影响 tool result，错误只打日志。
  Future<void> _uploadToWorker(List<int> bytes, String mac) async {
    try {
      final uri = Uri.parse('${ConfigProvider.WORKER_BASE}/vision/explain');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Device-Id'] = mac
        ..headers['dm'] = 'floki'
        ..files.add(http.MultipartFile.fromBytes(
          'image',
          bytes,
          filename: 'photo.jpg',
          contentType: MediaType('image', 'jpeg'),
        ));
      final resp = await request.send().timeout(const Duration(seconds: 20));
      final body = await resp.stream.bytesToString();
      print('[xz_dbg] take_photo: worker upload HTTP ${resp.statusCode} '
          'bodyLen=${body.length} mac=$mac');
    } catch (e) {
      print('[xz_dbg] take_photo: worker upload error: $e');
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

/// 12306 余票查询工具：查某日两地之间的列车余票（公开接口，无需登录）。
/// 在设备侧直接调 12306 公开查询 API——12306 对机房 IP 风控拦截查询，
/// 必须从手机（移动 IP）本机调，所以这个工具纯 Android 侧、不依赖任何服务器。
class QueryTrainTool extends McpTool {
  QueryTrainTool();

  /// 站名→编码 缓存（来自 station_name.js，进程内常驻）
  static Map<String, String>? _stationCodes;

  @override
  String get name => 'phone.query_train';

  @override
  String get description =>
      '查询 12306 某日两地之间的列车余票信息（公开接口，无需登录）。'
      '参数 from=出发站(如"北京")、to=到达站(如"上海")、date=日期(YYYY-MM-DD)。'
      '用于"查下周五北京到上海的高铁 / 看看明天去深圳还有没有票"等场景。'
      '返回各车次到发时间与各席别余票。';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'from': {'type': 'string', 'description': '出发站，如 北京、北京南'},
      'to': {'type': 'string', 'description': '到达站，如 上海、上海虹桥'},
      'date': {'type': 'string', 'description': '日期 YYYY-MM-DD，如 2026-08-07'},
    },
    'required': ['from', 'to', 'date'],
  };

  @override
  Future<McpToolResult> call(Map<String, dynamic> arguments) async {
    final fromName = arguments['from']?.toString().trim();
    final toName = arguments['to']?.toString().trim();
    final dateStr = arguments['date']?.toString().trim();
    if (fromName == null || toName == null || dateStr == null) {
      return McpToolResult(false, '请提供 from、to、date 三个参数');
    }
    final dateCompact = dateStr.replaceAll('-', '');
    if (!RegExp(r'^\d{8}$').hasMatch(dateCompact)) {
      return McpToolResult(false, '日期格式不对，需要 YYYY-MM-DD，如 2026-08-07');
    }

    const ua =
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

    print('[xz_dbg] query_train: start from=$fromName to=$toName date=$dateStr');
    try {
      // 1. 站名→编码
      final codes = await _stationCodesMap();
      final fromCode = _resolveCode(codes, fromName);
      final toCode = _resolveCode(codes, toName);
      print('[xz_dbg] query_train: station map size=${codes.length} '
          'fromCode=$fromCode toCode=$toCode');
      if (fromCode == null) {
        return McpToolResult(false, '找不到出发站「$fromName」');
      }
      if (toCode == null) {
        return McpToolResult(false, '找不到到达站「$toName」');
      }

      // 2. 先打 init 页拿 session cookie（12306 查询需要）
      final initResp = await http.get(
        Uri.parse('https://kyfw.12306.cn/otn/leftTicket/init'),
        headers: {'User-Agent': ua},
      ).timeout(const Duration(seconds: 15));
      final cookie = _extractCookie(initResp.headers['set-cookie']);
      print('[xz_dbg] query_train: init HTTP ${initResp.statusCode} '
          'cookieLen=${cookie.length}');

      // 3. 查询余票（http 默认跟随 302 到 queryZ/queryA 等真实端点）
      final queryResp = await http.get(
        Uri.parse(
            'https://kyfw.12306.cn/otn/leftTicket/query?leftTicketDTO.train_date=$dateCompact&leftTicketDTO.from_station=$fromCode&leftTicketDTO.to_station=$toCode&purpose_codes=ADULT'),
        headers: {
          'User-Agent': ua,
          'Referer': 'https://kyfw.12306.cn/otn/leftTicket/init',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
      ).timeout(const Duration(seconds: 20));
      print('[xz_dbg] query_train: query HTTP ${queryResp.statusCode} '
          'bodyLen=${queryResp.body.length} '
          'finalUrl=${queryResp.request?.url}');
      // 打印 body 头部，便于排查 12306 返回的是 JSON 还是错误页
      final head = queryResp.body.length > 200
          ? queryResp.body.substring(0, 200)
          : queryResp.body;
      print('[xz_dbg] query_train: body head=$head');

      if (queryResp.statusCode != 200) {
        return McpToolResult(false, '查询失败：12306 返回 ${queryResp.statusCode}');
      }
      final result = _parseQueryResponse(queryResp.body);
      print('[xz_dbg] query_train: parsed success=${result.success} '
          'textLen=${result.text.length}');
      return result;
    } on TimeoutException {
      print('[xz_dbg] query_train: timeout');
      return McpToolResult(false, '查询超时，12306 响应慢，请稍后再试');
    } on SocketException catch (e) {
      print('[xz_dbg] query_train: socket error ${e.message}');
      return McpToolResult(false, '网络错误：${e.message}');
    } catch (e) {
      print('[xz_dbg] query_train: error $e');
      return McpToolResult(false, '查询失败：$e');
    }
  }

  /// 获取并缓存站名→编码映射。station_name.js 格式：
  /// var station_names='@bjs|北京|BJP|beijing|bjs|0|0000|北京|@bjd|北京东|BOP|...'
  /// 每个 @ 分隔的条目里，第 2 字段是中文名，第 3 字段是站点编码。
  static Future<Map<String, String>> _stationCodesMap() async {
    if (_stationCodes != null && _stationCodes!.isNotEmpty) return _stationCodes!;
    final resp = await http.get(
      Uri.parse(
          'https://kyfw.12306.cn/otn/resources/js/framework/station_name.js'),
      headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://kyfw.12306.cn/otn/leftTicket/init',
      },
    ).timeout(const Duration(seconds: 15));
    final body = resp.body;
    final start = body.indexOf("'");
    final end = body.lastIndexOf("'");
    final m = <String, String>{};
    if (start >= 0 && end > start) {
      final content = body.substring(start + 1, end);
      for (final entry in content.split('@')) {
        if (entry.isEmpty) continue;
        final parts = entry.split('|');
        if (parts.length > 2) {
          final name = parts[1];
          final code = parts[2];
          if (name.isNotEmpty && code.isNotEmpty) {
            m[name] = code;
          }
        }
      }
    }
    _stationCodes = m;
    return m;
  }

  /// 精确匹配优先；否则取包含关系的（用户说"北京"可命中"北京"/"北京南"主码）。
  static String? _resolveCode(Map<String, String> m, String name) {
    if (m.containsKey(name)) return m[name];
    for (final k in m.keys) {
      if (k.contains(name) || name.contains(k)) return m[k];
    }
    return null;
  }

  /// 从 Set-Cookie 头提取 name=value 对，拼成 Cookie 头值。
  static String _extractCookie(String? setCookie) {
    if (setCookie == null || setCookie.isEmpty) return '';
    final re = RegExp(r'([A-Za-z_][\w-]+=[^;,]+)');
    return re.allMatches(setCookie).map((e) => e.group(0)!).toSet().join('; ');
  }

  /// 解析 12306 leftTicket 响应并格式化为可播报文本。
  /// 行格式（按 | 切分，以车次代码为锚，字段相对锚偏移，抗前导空字段位移）：
  ///   锚+1 出发站编码 / 锚+2 到达站编码 / 锚+5 出发时间 / 锚+6 到达 / 锚+7 历时
  ///   锚+26..+37 各席别余票
  static McpToolResult _parseQueryResponse(String body) {
    // 12306 响应可能带 BOM，先去掉
    final cleaned = body.replaceFirst('﻿', '').trim();
    // 12306 对机房/办公网 IP 会返回 HTML 错误页（不是 JSON），识别并给清晰提示
    if (cleaned.isEmpty || cleaned.startsWith('<') || !cleaned.startsWith('{')) {
      print('[xz_dbg] query_train: 非 JSON 响应，疑似 12306 风控拦截（IP 限制）');
      return McpToolResult(false,
          '12306 返回了错误页，当前网络可能被 12306 限制。请切换到 4G/5G 移动网络后再试。');
    }
    final decoded = jsonDecode(cleaned);
    if (decoded is! Map<String, dynamic>) {
      return McpToolResult(false, '12306 返回格式异常');
    }
    final data = decoded['data'];
    if (data is! Map) {
      final msg = decoded['messages']?.toString() ?? decoded['error_msg']?.toString();
      return McpToolResult(false, '12306 查询失败：${msg ?? '无数据'}');
    }
    final result = data['result'];
    final stationMap = (data['map'] is Map)
        ? Map<String, String>.from((data['map'] as Map).cast())
        : <String, String>{};
    if (result is! List || result.isEmpty) {
      return McpToolResult(true, '该日期路线暂无可用车次');
    }

    // 席别偏移（相对车次锚）→ 名称
    const seatOffsets = <int, String>{
      26: '商务/特等', 27: '特等', 28: '一等', 29: '二等',
      30: '高级软卧', 31: '软卧', 32: '动卧', 33: '硬卧',
      34: '软座', 35: '硬座', 36: '无座', 37: '其他',
    };

    final lines = <String>[];
    var shown = 0;
    for (final row in result) {
      if (row is! String || row.isEmpty) continue;
      final f = row.split('|');
      if (f.length < 11) continue;
      // 锚定车次字段：G/D/C/Z/T/K/L + 数字
      var tIdx = -1;
      for (var i = 0; i < f.length; i++) {
        if (RegExp(r'^[GDCZTKL]\d+$').hasMatch(f[i])) {
          tIdx = i;
          break;
        }
      }
      final train = tIdx >= 0 ? f[tIdx] : f[3];
      String fromName, toName;
      String depart, arrive, duration;
      if (tIdx >= 0) {
        fromName = (tIdx + 1 < f.length)
            ? (stationMap[f[tIdx + 1]] ?? f[tIdx + 1])
            : '';
        toName = (tIdx + 2 < f.length)
            ? (stationMap[f[tIdx + 2]] ?? f[tIdx + 2])
            : '';
        depart = (tIdx + 5 < f.length) ? f[tIdx + 5] : '';
        arrive = (tIdx + 6 < f.length) ? f[tIdx + 6] : '';
        duration = (tIdx + 7 < f.length) ? f[tIdx + 7] : '';
      } else {
        fromName = stationMap[f[4]] ?? f[4];
        toName = stationMap[f[5]] ?? f[5];
        depart = f[8];
        arrive = f[9];
        duration = f[10];
      }
      final seats = <String>[];
      seatOffsets.forEach((off, label) {
        final idx = (tIdx >= 0 ? tIdx : 3) + off;
        if (idx < f.length) {
          final v = f[idx].trim();
          if (v.isNotEmpty && v != '--' && v != '0') {
            seats.add('$label:$v');
          }
        }
      });
      final sb = StringBuffer('$train $fromName→$toName $depart-$arrive');
      if (duration.isNotEmpty) sb.write(' 历时$duration');
      if (seats.isNotEmpty) sb.write(' ${seats.join(' ')}');
      lines.add(sb.toString());
      shown++;
      if (shown >= 6) break; // 限制条数，避免 TTS 文本过长
    }
    if (lines.isEmpty) {
      return McpToolResult(true, '该日期路线暂无可用车次');
    }
    return McpToolResult(
      true,
      '查询到 ${result.length} 趟车次，前 $shown 趟：\n${lines.join('\n')}',
    );
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

  /// 本机设备 MAC（XiaozhiService 在 _init 注入），供 TakePhotoTool 上传 worker 时当 Device-Id。
  String macAddress = '';

  final List<McpTool> _tools = [];

  DeviceMcpTools() {
    _register(TakePhotoTool(channel, this));
    _register(QueryTrainTool());
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
