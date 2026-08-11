class XiaozhiConfig {
  final String id;
  final String name;
  final String websocketUrl;
  final String macAddress;
  final String token;
  final String configType; // "official" 或 "custom"
  final String? otaUrl; // 自定义 server 的 OTA 地址
  final String? clientId; // 自定义 server 的 CLIENT_ID (UUID)
  final String? workerBase; // 自建 Worker 的部署域名（用户输入，用于上传照片到 /vision/explain）
  final String lang; // 语言（自建 Worker 使用：zh-CN/zh-TW/en-US/ja-JP），默认 zh-CN
  final String firmwareVersion; // 设备当前固件版本（模拟 OTA 用，'-1'=未安装哨兵，默认 -1）

  XiaozhiConfig({
    required this.id,
    required this.name,
    required this.websocketUrl,
    required this.macAddress,
    required this.token,
    this.configType = 'official',
    this.otaUrl,
    this.clientId,
    this.workerBase,
    this.lang = 'zh-CN',
    this.firmwareVersion = '-1',
  });

  factory XiaozhiConfig.fromJson(Map<String, dynamic> json) {
    return XiaozhiConfig(
      id: json['id'],
      name: json['name'],
      websocketUrl: json['websocketUrl'],
      macAddress: json['macAddress'],
      token: json['token'],
      configType: json['configType'] ?? 'official',
      otaUrl: json['otaUrl'],
      clientId: json['clientId'],
      workerBase: json['workerBase'],
      lang: json['lang'] ?? 'zh-CN',
      firmwareVersion: json['firmwareVersion'] ?? '-1',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'websocketUrl': websocketUrl,
      'macAddress': macAddress,
      'token': token,
      'configType': configType,
      'otaUrl': otaUrl,
      'clientId': clientId,
      'workerBase': workerBase,
      'lang': lang,
      'firmwareVersion': firmwareVersion,
    };
  }

  XiaozhiConfig copyWith({
    String? name,
    String? websocketUrl,
    String? macAddress,
    String? token,
    String? configType,
    String? otaUrl,
    String? clientId,
    String? workerBase,
    String? lang,
    String? firmwareVersion,
  }) {
    return XiaozhiConfig(
      id: id,
      name: name ?? this.name,
      websocketUrl: websocketUrl ?? this.websocketUrl,
      macAddress: macAddress ?? this.macAddress,
      token: token ?? this.token,
      configType: configType ?? this.configType,
      otaUrl: otaUrl ?? this.otaUrl,
      clientId: clientId ?? this.clientId,
      workerBase: workerBase ?? this.workerBase,
      lang: lang ?? this.lang,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
    );
  }
}
