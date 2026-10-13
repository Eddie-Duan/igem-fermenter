import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_client.dart';
import '../ble/ble_protocol.dart';
import '../ble/ble_sync_service.dart';
import '../ble/fake_ble_client.dart';
import '../ble/reactive_ble_client.dart';
import '../models/control_state.dart';
import 'fermenter_controller.dart';

/// 设备连接与同步的界面状态机。
///
/// 界面只跟它打交道：扫描 → 连接 → 选批次同步 → 下发控制。
/// 传输细节在 [FermenterBleClient] 实现里，协议细节在 [BleSyncService] 里。
class BleDeviceManager extends ChangeNotifier {
  BleDeviceManager({
    required this.controller,
    FermenterBleClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? ReactiveBleClient.new;

  final FermenterController controller;

  /// 真机客户端的构造方式；测试里可以注入别的实现，避免碰平台通道。
  final FermenterBleClient Function() _clientFactory;

  FermenterBleClient? _client;
  BleSyncService? _sync;
  StreamSubscription<BleConnectionStatus>? _connectionSub;
  StreamSubscription<List<BleDevice>>? _scanSub;

  BleConnectionStatus connection = BleConnectionStatus.disconnected;
  List<BleDevice> devices = const [];
  BleDevice? connectedDevice;
  bool scanning = false;
  bool syncing = false;
  BleDeviceInfo? deviceInfo;
  BleLogStatus? logStatus;

  /// 当前绑定到设备的批次。
  int? boundProjectId;

  /// 本次绑定后已同步的条数（同步过程中递增）。
  int syncedCount = 0;

  /// 最近一次操作的结果说明。
  String? message;

  /// 最近一次失败原因。
  String? error;

  /// 已经下发到设备的控制状态，用来判断是否需要再发一次。
  ControlState? _lastPushedControl;
  bool _pushingControl = false;
  bool _observingController = false;

  bool get isConnected => connection == BleConnectionStatus.connected;

  /// 是否正拿一台"假设备"演示（没有硬件时用）。
  bool get isDemoDevice => _client is FakeBleClient;

  // -- 扫描与连接 --

  Future<void> startScan() async {
    final client = _ensureClient();
    scanning = true;
    error = null;
    devices = const [];
    notifyListeners();

    await _scanSub?.cancel();
    _scanSub = client.scan().listen(
      (found) {
        devices = found;
        notifyListeners();
      },
      onError: (Object failure) {
        scanning = false;
        error = _describe(failure);
        notifyListeners();
      },
    );
  }

  Future<void> stopScan() async {
    scanning = false;
    await _client?.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    notifyListeners();
  }

  Future<void> connect(BleDevice device) async {
    final client = _ensureClient();
    await stopScan();
    error = null;
    notifyListeners();
    try {
      await client.connect(device.id);
      connectedDevice = device;
      deviceInfo = await client.readDeviceInfo();
    } catch (failure) {
      connectedDevice = null;
      connection = BleConnectionStatus.failed;
      error = _describe(failure);
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _detach();
    try {
      await _client?.disconnect();
    } catch (_) {
      // 已经断开时平台会抛错，忽略。
    }
    connectedDevice = null;
    deviceInfo = null;
    logStatus = null;
    notifyListeners();
  }

  /// 没有硬件时的演示入口：接一台假设备，走的还是同一套连接/同步/实时链路。
  Future<void> connectDemoDevice() async {
    final demo = FakeBleClient(
      liveSamples: true,
      historyRecords: 400,
      sampleInterval: const Duration(seconds: 2),
    );
    await _replaceClient(demo);
    await connect(BleDevice(
      id: demo.deviceId,
      name: demo.deviceName,
      rssi: -58,
    ));
  }

  // -- 同步 --

  /// 把设备绑到某个批次并做一次全量同步；之后再来的采样会自动落库。
  Future<void> syncToProject(int projectId) async {
    final sync = _sync;
    if (sync == null || !isConnected) {
      error = 'Please connect the device first.';
      notifyListeners();
      return;
    }
    syncing = true;
    error = null;
    message = null;
    syncedCount = 0;
    notifyListeners();
    try {
      // 先打开批次：同步要读本地已有的最大序号，而且曲线会立刻刷新。
      await controller.selectProject(projectId);
      controller.bindDevice(projectId, connectedDevice?.displayName ?? 'ESP32-S3');
      // 绑定关系立刻生效（设备批次不再跑仿真）；同步失败也保持绑定，
      // 否则一次超时就会让真实批次退回仿真、往真数据里掺假点。
      boundProjectId = projectId;
      await sync.attach(projectId);
      final result = await sync.syncLog();
      syncedCount = result.stored;
      logStatus = sync.logStatus;
      final skipped = result.duplicates > 0
          ? '（跳过重复 ${result.duplicates} 条）'
          : '';
      message = 'Synced ${result.stored} readings from the device$skipped.';
      // 绑定之后盯住这个批次的搅拌/加热：详情页一改就自动下发。
      _startObservingControl();
      // 同步完顺手把当前控制状态下发，保证 App 与设备一致。
      await _pushControl(projectId);
    } on BleSyncException catch (failure) {
      error = failure.message;
      logStatus = null;
    } catch (failure) {
      error = _describe(failure);
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// 下发某个批次的搅拌/加热状态到设备。
  Future<void> pushControl(int projectId) async {
    try {
      await _pushControl(projectId);
      message = 'Device control updated.';
    } catch (failure) {
      error = _describe(failure);
    }
    notifyListeners();
  }

  Future<void> _pushControl(int projectId) async {
    final sync = _sync;
    if (sync == null || !isConnected) return;
    final control = _controlOf(projectId);
    if (control == null) return;
    _pushingControl = true;
    try {
      await sync.sendControl(control);
      _lastPushedControl = control;
    } finally {
      _pushingControl = false;
    }
  }

  /// 只解除批次绑定（批次回到本地仿真），保持设备连接。
  Future<void> unbind() async {
    final projectId = boundProjectId;
    await _detach();
    if (projectId != null) controller.unbindDevice(projectId);
    notifyListeners();
  }

  // -- 控制状态自动同步 --

  /// 批次绑定期间盯住控制器：详情页改了搅拌/加热，
  /// 不用每个页面都拿到 manager，这里自动补一次下发。
  void _startObservingControl() {
    if (_observingController) return;
    _observingController = true;
    controller.addListener(_onControllerChanged);
  }

  void _stopObservingControl() {
    if (!_observingController) return;
    _observingController = false;
    controller.removeListener(_onControllerChanged);
    _lastPushedControl = null;
  }

  void _onControllerChanged() {
    final projectId = boundProjectId;
    if (projectId == null || syncing || _pushingControl) return;
    final next = _controlOf(projectId);
    if (next == null) return;
    final last = _lastPushedControl;
    if (last != null &&
        last.stirrerOn == next.stirrerOn &&
        last.stirrerRpm == next.stirrerRpm &&
        last.heaterOn == next.heaterOn &&
        last.targetTempC == next.targetTempC) {
      return;
    }
    unawaited(_pushControl(projectId).catchError((Object failure) {
      error = _describe(failure);
      notifyListeners();
    }));
  }

  ControlState? _controlOf(int projectId) {
    final project = controller.projectById(projectId);
    if (project == null) return null;
    return ControlState(
      stirrerOn: project.stirrerOn,
      stirrerRpm: project.stirrerRpm,
      heaterOn: project.heaterOn,
      targetTempC: project.targetTempC,
    );
  }

  // -- 内部 --

  FermenterBleClient _ensureClient() {
    final existing = _client;
    if (existing != null) return existing;
    final client = _clientFactory();
    _client = client;
    final sync = BleSyncService(client: client, sink: controller)
      ..onProgress = _onSyncProgress;
    _sync = sync;
    _connectionSub = client.connectionStatus.listen(_onConnectionStatus);
    return client;
  }

  Future<void> _replaceClient(FermenterBleClient next) async {
    await _detach();
    await _connectionSub?.cancel();
    await _scanSub?.cancel();
    _connectionSub = null;
    _scanSub = null;
    await _sync?.dispose();
    _sync = null;
    final previous = _client;
    _client = next;
    if (previous != null && !identical(previous, next)) {
      await previous.dispose();
    }
    _sync = BleSyncService(client: next, sink: controller)
      ..onProgress = _onSyncProgress;
    _connectionSub = next.connectionStatus.listen(_onConnectionStatus);
  }

  Future<void> _detach() async {
    await _sync?.detach();
    _stopObservingControl();
    boundProjectId = null;
    syncedCount = 0;
  }

  void _onConnectionStatus(BleConnectionStatus status) {
    connection = status;
    if (status == BleConnectionStatus.disconnected ||
        status == BleConnectionStatus.failed) {
      // 断开时停掉接收，但**不解除批次绑定**：这是设备批次，
      // 设备回来之后接着同步，不该偷偷退回本地仿真。
      unawaited(_sync?.detach());
    }
    notifyListeners();
  }

  void _onSyncProgress(int stored) {
    syncedCount = stored;
    // 一次同步可能几百条：每 10 条刷一次界面就够了。
    if (stored % 10 == 0) notifyListeners();
  }

  String _describe(Object failure) {
    if (failure is BleSyncException) return failure.message;
    if (failure is StateError) return failure.message;
    return 'Bluetooth error: $failure';
  }

  @override
  void dispose() {
    _stopObservingControl();
    unawaited(_connectionSub?.cancel());
    unawaited(_scanSub?.cancel());
    unawaited(_sync?.dispose());
    final client = _client;
    _client = null;
    _sync = null;
    if (client != null) unawaited(client.dispose());
    super.dispose();
  }
}
