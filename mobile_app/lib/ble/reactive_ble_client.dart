import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' as rble;

import 'ble_client.dart';
import 'ble_protocol.dart';

/// 真机实现（`flutter_reactive_ble` 5.5.0）。
///
/// **整个 App 里只有这一个文件直接依赖 BLE 库。** 换库、或升级后 API 有变动，
/// 只需要改这里；协议编解码、同步流程、控制器和界面都只依赖
/// [FermenterBleClient] 抽象。
///
/// 与 5.x 的几个要点：
/// - `connectToDevice()` 返回的是**按设备过滤的连接状态流**，必须 `listen`
///   才会真正发起连接；断开就是取消这个订阅（库没有单独的 disconnect）。
/// - 读写/订阅统一用 [rble.QualifiedCharacteristic]（service + characteristic
///   + device 三个 UUID），不用自己先跑一遍服务发现。
/// - 连接状态枚举叫 `DeviceConnectionState`（不是 Flutter 的 `ConnectionState`）。
///
/// 需要 Android 侧权限（见 `android/app/src/main/AndroidManifest.xml`）。
class ReactiveBleClient implements FermenterBleClient {
  ReactiveBleClient({rble.FlutterReactiveBle? ble})
      : _ble = ble ?? rble.FlutterReactiveBle();

  final rble.FlutterReactiveBle _ble;

  final _sensorData = StreamController<Uint8List>.broadcast();
  final _status = StreamController<Uint8List>.broadcast();
  final _connection = StreamController<BleConnectionStatus>.broadcast();

  StreamSubscription<rble.ConnectionStateUpdate>? _connectionSub;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<rble.DiscoveredDevice>? _scanSub;
  Timer? _scanTimer;
  StreamController<List<BleDevice>>? _scanController;

  rble.QualifiedCharacteristic? _infoCharacteristic;
  rble.QualifiedCharacteristic? _sensorCharacteristic;
  rble.QualifiedCharacteristic? _controlCharacteristic;
  rble.QualifiedCharacteristic? _statusCharacteristic;

  @override
  Stream<List<BleDevice>> scan({Duration timeout = const Duration(seconds: 15)}) {
    unawaited(stopScan());
    final controller = StreamController<List<BleDevice>>();
    final found = <String, BleDevice>{};
    _scanController = controller;

    _scanSub = _ble
        .scanForDevices(
          // 只扫广播里带本服务 UUID 的设备（固件必须广播它）。
          withServices: [rble.Uuid.parse(BleUuids.service)],
          scanMode: rble.ScanMode.lowLatency,
        )
        .listen(
      (device) {
        found[device.id] = BleDevice(
          id: device.id,
          name: device.name,
          rssi: device.rssi,
        );
        if (!controller.isClosed) {
          controller.add(found.values.toList(growable: false));
        }
      },
      onError: (Object error) {
        if (!controller.isClosed) controller.addError(error);
      },
    );
    _scanTimer = Timer(timeout, () => unawaited(stopScan()));
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    final controller = _scanController;
    _scanController = null;
    if (controller != null && !controller.isClosed) await controller.close();
  }

  @override
  Stream<BleConnectionStatus> get connectionStatus => _connection.stream;

  @override
  Stream<Uint8List> get sensorData => _sensorData.stream;

  @override
  Stream<Uint8List> get status => _status.stream;

  @override
  Future<void> connect(String deviceId) async {
    await disconnect();
    _connection.add(BleConnectionStatus.connecting);

    final connected = Completer<void>();
    _connectionSub = _ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
      (update) {
        switch (update.connectionState) {
          case rble.DeviceConnectionState.connected:
            _connection.add(BleConnectionStatus.connected);
            if (!connected.isCompleted) connected.complete();
          case rble.DeviceConnectionState.connecting:
          case rble.DeviceConnectionState.disconnecting:
            _connection.add(BleConnectionStatus.connecting);
          case rble.DeviceConnectionState.disconnected:
            if (update.failure != null) {
              _connection.add(BleConnectionStatus.failed);
              if (!connected.isCompleted) {
                connected.completeError(
                    StateError('连接失败：${update.failure!.message}'));
              }
            } else {
              _connection.add(BleConnectionStatus.disconnected);
              if (!connected.isCompleted) {
                connected.completeError(StateError('设备已断开连接'));
              }
            }
        }
      },
      onError: (Object error) {
        _connection.add(BleConnectionStatus.failed);
        if (!connected.isCompleted) connected.completeError(error);
      },
      cancelOnError: false,
    );

    try {
      await connected.future;
      _prepareCharacteristics(deviceId);
      await _subscribe();
    } catch (error) {
      // 连不上或订阅不上都收拾干净，别留一个半开的连接。
      await disconnect();
      rethrow;
    }
  }

  /// 特征值直接按协议里的 UUID 构造：App 只认这四个，
  /// 库内部会在第一次读写/订阅时自己完成服务发现。
  void _prepareCharacteristics(String deviceId) {
    final serviceId = rble.Uuid.parse(BleUuids.service);
    rble.QualifiedCharacteristic characteristic(String uuid) =>
        rble.QualifiedCharacteristic(
          serviceId: serviceId,
          characteristicId: rble.Uuid.parse(uuid),
          deviceId: deviceId,
        );

    _infoCharacteristic = characteristic(BleUuids.deviceInfo);
    _sensorCharacteristic = characteristic(BleUuids.sensorData);
    _controlCharacteristic = characteristic(BleUuids.syncControl);
    _statusCharacteristic = characteristic(BleUuids.syncStatus);
  }

  Future<void> _subscribe() async {
    final sensor = _sensorCharacteristic;
    final status = _statusCharacteristic;
    if (sensor == null || status == null) {
      throw StateError('设备未连接，无法订阅特征值');
    }
    try {
      await _dataSub?.cancel();
      _dataSub = _ble.subscribeToCharacteristic(sensor).listen(
            (data) => _sensorData.add(Uint8List.fromList(data)),
            onError: _reportStreamFailure,
          );
      await _statusSub?.cancel();
      _statusSub = _ble.subscribeToCharacteristic(status).listen(
            (data) => _status.add(Uint8List.fromList(data)),
            onError: _reportStreamFailure,
          );
    } catch (error) {
      throw StateError(
          '设备没有提供发酵罐服务（${BleUuids.service}）；'
          '请确认固件版本与 docs/ble-gatt.md 一致。原始错误：$error');
    }
  }

  /// 订阅中途出错（设备重启、UUID 对不上）：把连接标成失败，
  /// 让界面提示重连，而不是让错误在流里静默丢掉。
  void _reportStreamFailure(Object error) {
    debugPrint('BLE 订阅出错：$error');
    _connection.add(BleConnectionStatus.failed);
  }

  @override
  Future<void> disconnect() async {
    await _dataSub?.cancel();
    _dataSub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    // 5.x 没有单独的断开方法：取消 connectToDevice 返回的订阅即是断开。
    await _connectionSub?.cancel();
    _connectionSub = null;
    _infoCharacteristic = null;
    _sensorCharacteristic = null;
    _controlCharacteristic = null;
    _statusCharacteristic = null;
    _connection.add(BleConnectionStatus.disconnected);
  }

  @override
  Future<BleDeviceInfo?> readDeviceInfo() async {
    final characteristic = _infoCharacteristic;
    if (characteristic == null) return null;
    try {
      return BleDeviceInfo.fromBytes(
          await _ble.readCharacteristic(characteristic));
    } catch (error) {
      // 读不到设备信息不该挡住同步：界面显示 "—" 就好。
      debugPrint('读取 DeviceInfo 失败：$error');
      return null;
    }
  }

  @override
  Future<void> writeControl(Uint8List frame) async {
    final characteristic = _controlCharacteristic;
    if (characteristic == null) {
      throw StateError('设备未连接，无法下发指令');
    }
    await _ble.writeCharacteristicWithResponse(characteristic, value: frame);
  }

  /// 断开连接后释放资源。
  Future<void> dispose() async {
    await disconnect();
    await _sensorData.close();
    await _status.close();
    await _connection.close();
  }
}
