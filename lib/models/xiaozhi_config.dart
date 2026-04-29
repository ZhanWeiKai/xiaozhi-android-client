class XiaozhiConfig {
  final String id;
  final String name;
  final String websocketUrl;
  final String macAddress;
  final String token;
  final String configType; // "official" 或 "custom"
  final String? otaUrl; // 自定义 server 的 OTA 地址
  final String? clientId; // 自定义 server 的 CLIENT_ID (UUID)

  XiaozhiConfig({
    required this.id,
    required this.name,
    required this.websocketUrl,
    required this.macAddress,
    required this.token,
    this.configType = 'official',
    this.otaUrl,
    this.clientId,
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
    );
  }
}
