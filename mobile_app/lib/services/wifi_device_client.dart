import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../ble/ble_protocol.dart';

/// 连接设备本地 HTTP API 所需的地址与凭据。
class WifiCredentials {
  const WifiCredentials({
    required this.address,
    required this.password,
    this.username = 'admin',
  });

  /// 形如 `192.168.4.1`（设备热点）或路由器分配给设备的地址。
  final String address;
  final String username;

  /// 设备串口日志里打印的 web 密码（AP 密码与网页登录密码相同）。
  final String password;

  WifiCredentials copyWith({String? address}) => WifiCredentials(
        address: address ?? this.address,
        username: username,
        password: password,
      );

  @override
  String toString() => 'WifiCredentials($username@$address)';
}

/// `GET /api/status` 的快照。
///
/// 字段保留在 [raw] 里，界面要显示什么直接取；协议相关的少数字段给出类型化访问器。
class WifiStatus {
  WifiStatus(this.raw);

  final Map<String, dynamic> raw;

  /// 固件是否提供同步接口（`/api/readings` 等）。0 表示只有网页 API。
  int get apiVersion => _int('apiVersion');

  /// `1.1.0` → `0x00010100`；解析失败返回 0。
  int get firmwareVersion {
    final text = raw['firmware'];
    if (text is! String) return 0;
    final parts = text.split('.');
    if (parts.length != 3) return 0;
    int part(int index) => int.tryParse(parts[index]) ?? 0;
    return ((part(0) & 0xFF) << 16) | ((part(1) & 0xFF) << 8) | (part(2) & 0xFF);
  }

  String get firmwareLabel => raw['firmware'] as String? ?? '—';

  String get deviceId => raw['deviceId'] as String? ?? '';

  bool get logReady => raw['logReady'] == true;

  int get oldestSeq => _int('oldestSeq');
  int get nextSeq => _int('nextSeq');
  int get recordCount => _int('recordCount');
  int get logCapacity => _int('logCapacity');
  int get sampleIntervalS => _int('sampleIntervalS');

  bool get stirrerSupported => raw['stirrerSupported'] == true;

  int _int(String key) => (raw[key] as num?)?.toInt() ?? 0;
}

/// 设备 flash 日志里的一条记录（已解码的物理量）。
class WifiReading {
  const WifiReading({
    required this.seq,
    required this.timestamp,
    required this.temperatureC,
    required this.ph,
    required this.od,
    this.batteryMv = 0,
  });

  final int seq;

  /// Unix 秒；设备未校时为 0。
  final int timestamp;
  final double temperatureC;
  final double ph;
  final double od;
  final int batteryMv;

  /// 转成与 BLE 完全相同的 20 字节帧，这样同步服务不必区分传输方式。
  Uint8List toFrame() => BleReadingRecord(
        seq: seq,
        timestamp: timestamp,
        temperatureC: temperatureC,
        ph: ph,
        od: od,
        batteryMv: batteryMv,
      ).toBytes();

  factory WifiReading.fromJson(Map<String, dynamic> json) {
    final seq = (json['seq'] as num?)?.toInt();
    if (seq == null) throw const FormatException('reading without seq');
    return WifiReading(
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
      'WifiReading(seq: $seq, t: $temperatureC °C, pH: $ph, OD: $od)';
}

/// `GET /api/readings` 的分页结果。
class WifiReadingsPage {
  const WifiReadingsPage({
    required this.oldest,
    required this.next,
    required this.count,
    required this.since,
    required this.records,
  });

  final int oldest;
  final int next;
  final int count;
  final int since;
  final List<WifiReading> records;

  bool get hasMore => since + records.length < next;

  factory WifiReadingsPage.fromJson(Map<String, dynamic> json) {
    final list = json['records'];
    if (list is! List) throw const FormatException('missing records array');
    return WifiReadingsPage(
      oldest: (json['oldest'] as num?)?.toInt() ?? 0,
      next: (json['next'] as num?)?.toInt() ?? 0,
      count: (json['count'] as num?)?.toInt() ?? 0,
      since: (json['since'] as num?)?.toInt() ?? 0,
      records: [
        for (final item in list)
          if (item is Map<String, dynamic>) WifiReading.fromJson(item),
      ],
    );
  }
}

/// 设备 HTTP API 的抽象：真机用 [WifiDeviceClient]，单测里可以注入假实现。
abstract class WifiDeviceApi {
  Future<WifiStatus> status(WifiCredentials credentials);

  Future<WifiReadingsPage> readings(
    WifiCredentials credentials, {
    required int since,
    int limit = 60,
  });

  Future<void> commit(WifiCredentials credentials, int lastSeq);

  Future<void> setControl(
    WifiCredentials credentials, {
    required double targetTempC,
    required bool heaterEnabled,
    bool stirrerEnabled = false,
    int stirrerRpm = 0,
  });

  Future<void> setTime(WifiCredentials credentials, DateTime now);

  Future<void> close();
}

/// ESP32-S3 本地 HTTP API 客户端（Basic Auth）。
///
/// 端点与字段见 `docs/wifi-api.md`，固件实现在
/// `firmware/esp32-s3/main/src/modules/network/network_manager.cpp`。
class WifiDeviceClient implements WifiDeviceApi {
  WifiDeviceClient({HttpClient? httpClient}) : _http = httpClient ?? HttpClient();

  final HttpClient _http;

  @override
  Future<WifiStatus> status(WifiCredentials credentials) async =>
      WifiStatus(await _request(credentials, 'GET', '/api/status'));

  @override
  Future<WifiReadingsPage> readings(
    WifiCredentials credentials, {
    required int since,
    int limit = 60,
  }) async =>
      WifiReadingsPage.fromJson(await _request(
        credentials,
        'GET',
        '/api/readings',
        query: {'since': '$since', 'limit': '$limit'},
      ));

  @override
  Future<void> commit(WifiCredentials credentials, int lastSeq) async {
    await _request(credentials, 'POST', '/api/readings/commit',
        form: {'last': '$lastSeq'});
  }

  @override
  Future<void> setControl(
    WifiCredentials credentials, {
    required double targetTempC,
    required bool heaterEnabled,
    bool stirrerEnabled = false,
    int stirrerRpm = 0,
  }) async {
    await _request(credentials, 'POST', '/api/control', form: {
      'target': targetTempC.toStringAsFixed(1),
      'heater': heaterEnabled ? '1' : '0',
      'stirrer': stirrerEnabled ? '1' : '0',
      'rpm': '$stirrerRpm',
    });
  }

  @override
  Future<void> setTime(WifiCredentials credentials, DateTime now) async {
    await _request(credentials, 'POST', '/api/time', form: {
      'now': '${now.toUtc().millisecondsSinceEpoch ~/ 1000}',
    });
  }

  Future<Map<String, dynamic>> _request(
    WifiCredentials credentials,
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
  }) async {
    final host = credentials.address
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    if (host.isEmpty || host.contains('/') || host.contains(' ')) {
      throw const FormatException(
          'Enter the ESP32 IP address, for example 192.168.4.1.');
    }
    var uri = Uri.parse('http://$host$path');
    if (query != null) uri = uri.replace(queryParameters: query);

    final request = await _http.openUrl(method, uri)
        .timeout(const Duration(seconds: 5));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('${credentials.username}:${credentials.password}'))}',
    );
    if (query != null) {
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    }
    if (form != null) {
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      request.write(form.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'));
    }

    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401) {
        throw const HttpException('Incorrect web password.');
      }
      final message = _errorMessage(body);
      throw HttpException(
          message ?? 'Device returned HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid device response.');
    }
    return decoded;
  }

  /// 固件错误响应形如 `{"error":"..."}`；解析失败就退回原始文本。
  static String? _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // not JSON
    }
    return null;
  }

  @override
  Future<void> close() async => _http.close(force: true);
}

