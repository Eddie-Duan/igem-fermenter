import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_client.dart';

/// ESP32-S3 本地 HTTP API 客户端（Basic Auth）。
///
/// 端点与字段见 `docs/wifi-api.md`，固件实现在
/// `firmware/esp32-s3/main/src/modules/network/network_manager.cpp`。
class HttpDeviceClient implements DeviceClient {
  HttpDeviceClient({HttpClient? httpClient})
      : _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 5);
  }

  final HttpClient _http;
  final _connection = StreamController<DeviceConnectionStatus>.broadcast();

  DeviceCredentials? _credentials;
  bool _connected = false;

  /// 最近一次 `GET /api/status` 的快照。
  DeviceStatus? lastStatus;

  DeviceCredentials? get credentials => _credentials;
  bool get isConnected => _connected;

  @override
  Stream<DeviceConnectionStatus> get connectionStatus => _connection.stream;

  @override
  Future<void> connect(DeviceCredentials credentials) async {
    _connection.add(DeviceConnectionStatus.connecting);
    _credentials = credentials;
    try {
      final status = await refreshStatus();
      if (!status.supportsSync) {
        throw StateError(
            'This firmware has no sync API (apiVersion ${status.apiVersion}). '
            'Flash the latest firmware from firmware/esp32-s3/main.');
      }
      _connected = true;
      _connection.add(DeviceConnectionStatus.connected);
    } catch (error) {
      _connected = false;
      _connection.add(DeviceConnectionStatus.failed);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    if (!_connection.isClosed) {
      _connection.add(DeviceConnectionStatus.disconnected);
    }
  }

  @override
  Future<DeviceStatus> refreshStatus() async {
    final status = DeviceStatus(
        await _request('GET', '/api/status'));
    lastStatus = status;
    return status;
  }

  @override
  Future<DeviceReadingsPage> readings({
    required int since,
    int limit = 60,
  }) async {
    final json = await _request('GET', '/api/readings',
        query: {'since': '$since', 'limit': '$limit'});
    return DeviceReadingsPage.fromJson(json);
  }

  @override
  Future<void> commit(int lastSeq) =>
      _request('POST', '/api/readings/commit', form: {'last': '$lastSeq'});

  @override
  Future<void> setControl({
    required bool stirrerOn,
    required int stirrerRpm,
    required bool heaterOn,
    required double targetTempC,
  }) =>
      _request('POST', '/api/control', form: {
        'target': targetTempC.toStringAsFixed(1),
        'heater': heaterOn ? '1' : '0',
        'stirrer': stirrerOn ? '1' : '0',
        'rpm': '$stirrerRpm',
      });

  @override
  Future<void> setTime(DateTime now) => _request('POST', '/api/time', form: {
        'now': '${now.toUtc().millisecondsSinceEpoch ~/ 1000}',
      });

  @override
  Future<void> close() async {
    _connected = false;
    await _connection.close();
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
  }) async {
    final credentials = _credentials;
    if (credentials == null) {
      throw StateError('Not connected to a device yet.');
    }
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
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (form != null) {
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      request.write(form.entries
          .map((entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
          .join('&'));
    }

    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401) {
        throw const HttpException(
            'Wrong Web password. The device prints it on its serial log at boot.');
      }
      throw HttpException(_errorMessage(body) ??
          'Device returned HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid device response.');
    }
    return decoded;
  }

  /// 固件错误响应形如 `{"error":"..."}`；解析失败就返回 null。
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
}
