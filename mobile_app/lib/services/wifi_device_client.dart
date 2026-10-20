import 'dart:convert';
import 'dart:io';

/// HTTP client for the ESP32-S3's authenticated local status/control API.
class WifiDeviceClient {
  WifiDeviceClient({HttpClient? httpClient}) : _http = httpClient ?? HttpClient();

  final HttpClient _http;

  Future<Map<String, dynamic>> status({
    required String address,
    required String username,
    required String password,
  }) =>
      _request(address, username, password, '/api/status');

  Future<Map<String, dynamic>> setControl({
    required String address,
    required String username,
    required String password,
    required double targetTempC,
    required bool heaterEnabled,
  }) =>
      _request(address, username, password, '/api/control', {
        'target': targetTempC.toStringAsFixed(1),
        'heater': heaterEnabled ? '1' : '0',
      });

  Future<Map<String, dynamic>> _request(
    String address,
    String username,
    String password,
    String path, [
    Map<String, String>? form,
  ]) async {
    final host = address
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    if (host.isEmpty || host.contains('/') || host.contains(' ')) {
      throw const FormatException('Enter the ESP32 IP address, for example 192.168.4.1.');
    }
    final request = await _http
        .openUrl(form == null ? 'GET' : 'POST', Uri.parse('http://$host$path'))
        .timeout(const Duration(seconds: 5));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('$username:$password'))}',
    );
    if (form != null) {
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      request.write(form.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'));
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401) throw const HttpException('Incorrect web password.');
      throw HttpException('Device returned HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw const FormatException('Invalid device response.');
    return decoded;
  }

  void close() => _http.close(force: true);
}
