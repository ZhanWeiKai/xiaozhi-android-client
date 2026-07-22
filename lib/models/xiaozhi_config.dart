class XiaozhiConfig {
  final String id;
  final String name;
  final String websocketUrl;
  final String macAddress;
  final String token;
  final String configType; // "official" 或 "custom"
  final String? otaUrl; // 自定义 server 的 OTA 地址
  final String? clientId; // 自定义 server 的 CLIENT_ID (UUID)
  final String lang; // 语言（自建 Worker 使用：zh-CN/zh-TW/en-US/ja-JP），默认 zh-CN

  XiaozhiConfig({
    required this.id,
    required this.name,
    required this.websocketUrl,
    required this.macAddress,
    required this.token,
    this.configType = 'official',
    this.otaUrl,
    this.clientId,
    this.lang = 'zh-CN',
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
      lang: json['lang'] ?? 'zh-CN',
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
      'lang': lang,
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
    String? lang,
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
      lang: lang ?? this.lang,
    );
  }
}
