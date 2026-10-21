import 'package:flutter/foundation.dart';

/// 设备连接状态。
enum DeviceConnectionStatus {
  disconnected,
  connecting,
  connected,

  /// 连接失败或中途断开，使用方负责提示重试。
  failed,
}

/// 连接设备所需的地址与凭据。
///
/// 设备始终开着一个配置热点（`192.168.4.1`，SSID 见串口日志），
/// 也可以用 `POST /api/wifi` 让它连上路由器，之后改用路由器分配的地址。
@immutable
class DeviceCredentials {
  const DeviceCredentials({
    required this.address,
    required this.password,
    this.username = 'admin',
  });

  /// 形如 `192.168.4.1` 或 `192.168.1.42`（可带 `http://`，会被去掉）。
  final String address;
  final String username;

  /// 网页登录密码，同时是配置热点的密码；每次启动会打印在串口日志里。
  final String password;

  DeviceCredentials copyWith({String? address, String? password}) =>
      DeviceCredentials(
        address: address ?? this.address,
        username: username,
        password: password ?? this.password,
      );

  @override
  String toString() => 'DeviceCredentials($username@$address)';
}

/// `GET /api/status` 的快照。
///
/// 原始 JSON 保留在 [raw]，界面可直接取值；常用字段另有类型化访问器。
class DeviceStatus {
  const DeviceStatus(this.raw);

  final Map<String, dynamic> raw;

  static const int supportedApiVersion = 1;

  /// 固件是否提供同步接口。0 表示只有网页 API，App 无法拉历史记录。
  int get apiVersion => _int('apiVersion');

  bool get supportsSync => apiVersion >= supportedApiVersion;

  /// `1.1.0` 文本。
  String get firmwareLabel => raw['firmware'] as String? ?? '—';

  /// `1.1.0` → `0x00010100`；解析失败返回 0。
  int get firmwareVersion {
    final parts = firmwareLabel.split('.');
    if (parts.length != 3) return 0;
    int part(int index) => int.tryParse(parts[index]) ?? 0;
    return ((part(0) & 0xFF) << 16) |
        ((part(1) & 0xFF) << 8) |
        (part(2) & 0xFF);
  }

  /// 设备标识（Wi-Fi MAC），用于区分不同板子。
  String get deviceId => raw['deviceId'] as String? ?? '';

  int get oldestSeq => _int('oldestSeq');
  int get nextSeq => _int('nextSeq');
  int get recordCount => _int('recordCount');
  int get logCapacity => _int('logCapacity');
  bool get logReady => raw['logReady'] == true;

  /// 记录周期（秒）。实验时间轴按 `seq × sampleIntervalS` 换算。
  int get sampleIntervalS => _int('sampleIntervalS');

  bool get stirrerSupported => raw['stirrerSupported'] == true;
  bool get stirrerOn => raw['stirrerOn'] == true;
  int get stirrerRpm => _int('stirrerRpm');

  bool get heaterEnabled => raw['heaterEnabled'] == true;
  bool get heaterOn => raw['heaterOn'] == true;
  double get targetTempC => _double('targetTempC');

  bool get mqttConnected => raw['mqttConnected'] == true;
  bool get wifiConnected => raw['wifiConnected'] == true;

  /// 路由器分配的地址（没连上时为空串）。
  String get stationIp => raw['staIp'] as String? ?? '';
  String get accessPointIp => raw['apIp'] as String? ?? '';

  double get temperatureC => _double('tempC');
  double get ph => _double('ph');
  double get odProxy => _double('odProxy');
  bool get alarm => raw['alarm'] == true;

  int _int(String key) => (raw[key] as num?)?.toInt() ?? 0;
  double _double(String key) => (raw[key] as num?)?.toDouble() ?? 0;
}

/// 设备 flash 日志里的一条记录。
class DeviceReading {
  const DeviceReading({
    required this.seq,
    required this.timestamp,
    required this.temperatureC,
    required this.ph,
    required this.od,
    this.batteryMv = 0,
  });

  final int seq;

  /// Unix 秒；设备未校时为 0，App 用手机时间占位。
  final int timestamp;
  final double temperatureC;
  final double ph;

  /// 相对光衰减（沿用 App 的 OD 曲线位）；不是已标定的 OD600。
  final double od;
  final int batteryMv;

  factory DeviceReading.fromJson(Map<String, dynamic> json) {
    final seq = (json['seq'] as num?)?.toInt();
    if (seq == null) throw const FormatException('reading without seq');
    return DeviceReading(
      seq: seq,
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      temperatureC: (json['tempC'] as num?)?.toDouble() ?? 0,
      ph: (json['ph'] as num?)?.toDouble() ?? 0,
      od: (json['od'] as num?)?.toDouble() ?? 0,
      batteryMv: (json['batteryMv'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'DeviceReading(seq: $seq, t: $temperatureC °C, pH: $ph, OD: $od)';
}

/// `GET /api/readings` 的一页结果。
class DeviceReadingsPage {
  const DeviceReadingsPage({
    required this.oldest,
    required this.next,
    required this.count,
    required this.since,
    required this.records,
  });

  /// 设备现存的第一条序号（更早的已被回收）。
  final int oldest;

  /// 设备下一条待写入的序号，也是本次同步的上界。
  final int next;
  final int count;
  final int since;
  final List<DeviceReading> records;

  factory DeviceReadingsPage.fromJson(Map<String, dynamic> json) {
    final list = json['records'];
    if (list is! List) throw const FormatException('missing records array');
    return DeviceReadingsPage(
      oldest: (json['oldest'] as num?)?.toInt() ?? 0,
      next: (json['next'] as num?)?.toInt() ?? 0,
      count: (json['count'] as num?)?.toInt() ?? 0,
      since: (json['since'] as num?)?.toInt() ?? 0,
      records: [
        for (final item in list)
          if (item is Map<String, dynamic>) DeviceReading.fromJson(item),
      ],
    );
  }
}

/// 设备传输层抽象。
///
/// 现在只有 HTTP 一个实现（[HttpDeviceClient]），保留接口是为了让同步逻辑、
/// 管理器与界面能脱离网络单测，也方便以后加别的传输方式。
abstract class DeviceClient {
  Stream<DeviceConnectionStatus> get connectionStatus;

  /// 连接并校验固件版本；失败抛异常。
  Future<void> connect(DeviceCredentials credentials);

  Future<void> disconnect();

  /// 重新拉取一次设备状态。
  Future<DeviceStatus> refreshStatus();

  /// 按序号读取 flash 日志（`since` 含端点）。
  Future<DeviceReadingsPage> readings({required int since, int limit = 60});

  /// 告诉设备这些序号已落库，可以回收。
  Future<void> commit(int lastSeq);

  Future<void> setControl({
    required bool stirrerOn,
    required int stirrerRpm,
    required bool heaterOn,
    required double targetTempC,
  });

  /// 用手机时钟校准设备。
  Future<void> setTime(DateTime now);

  /// 断开并释放资源。
  Future<void> close();
}
