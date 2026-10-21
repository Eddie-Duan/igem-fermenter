import 'dart:async';

import 'package:flutter/foundation.dart';

import '../device/device_client.dart';
import '../device/device_sync_service.dart';
import '../device/fake_device_client.dart';
import '../device/http_device_client.dart';
import '../models/control_state.dart';
import 'fermenter_controller.dart';

/// 设备连接与同步的界面状态机。
///
/// 界面只跟它打交道：填地址 → 连接 → 选批次同步 → 下发控制。
/// 传输细节在 [DeviceClient] 里，协议细节在 [DeviceSyncService] 里。
class DeviceManager extends ChangeNotifier {
  DeviceManager({
    required this.controller,
    DeviceClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpDeviceClient.new;

  final FermenterController controller;

  /// 真机客户端的构造方式；测试里可以注入别的实现，避免碰网络。
  final DeviceClient Function() _clientFactory;

  DeviceClient? _client;
  DeviceSyncService? _sync;
  StreamSubscription<DeviceConnectionStatus>? _connectionSub;

  DeviceConnectionStatus connection = DeviceConnectionStatus.disconnected;
  DeviceCredentials? credentials;
  DeviceStatus? status;
  bool syncing = false;

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

  bool get isConnected => connection == DeviceConnectionStatus.connected;

  /// 是否正拿一台"假设备"演示（没有硬件时用）。
  bool get isDemoDevice => _client is FakeDeviceClient;

  String? get address => credentials?.address;

  /// 设备上的日志范围（未连接时为 null）。
  ({int oldest, int next, int count})? get logRange {
    final current = status;
    if (current == null) return null;
    return (
      oldest: current.oldestSeq,
      next: current.nextSeq,
      count: current.recordCount,
    );
  }

  /// 是否显示为"同步中"（含连接后的状态刷新）。
  String? get deviceId => status?.deviceId;

  // -- 连接 --

  /// 连接真机。地址是配置热点 `192.168.4.1` 或路由器分配的 IP。
  Future<void> connect({
    required String address,
    required String password,
    String username = 'admin',
  }) async {
    error = null;
    message = null;
    notifyListeners();

    // 换地址/凭据时重建客户端，旧连接由 _replaceClient 关掉。
    await _replaceClient(_clientFactory());
    final target = _client!;
    credentials = DeviceCredentials(
        address: address, username: username, password: password);
    try {
      await target.connect(credentials!);
      status = await target.refreshStatus();
      message = 'Connected to ${credentials!.address} over Wi-Fi.';
    } catch (failure) {
      connection = DeviceConnectionStatus.failed;
      error = _describe(failure);
    }
    notifyListeners();
  }

  /// 没有硬件时的演示入口：接一台假设备，走的还是同一套连接/同步/实时链路。
  Future<void> connectDemoDevice() async {
    await _replaceClient(FakeDeviceClient(
      sampleInterval: const Duration(seconds: 2),
      historyRecords: 400,
    ));
    credentials = const DeviceCredentials(
      address: 'demo',
      password: 'demo',
    );
    try {
      await _client!.connect(credentials!);
      status = await _client!.refreshStatus();
      message = 'Demo device connected.';
    } catch (failure) {
      connection = DeviceConnectionStatus.failed;
      error = _describe(failure);
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _detach();
    try {
      await _client?.disconnect();
    } catch (_) {
      // 已经断开时忽略。
    }
    credentials = null;
    status = null;
    notifyListeners();
  }

  /// 重新读取设备状态（电池/温度/日志范围）。
  Future<void> refreshStatus() async {
    final client = _client;
    if (client == null || !isConnected) return;
    try {
      status = await client.refreshStatus();
    } catch (failure) {
      error = _describe(failure);
    }
    notifyListeners();
  }

  // -- 同步 --

  /// 把设备绑定到某个批次并做一次全量同步；之后新采样继续自动落库。
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
      controller.bindDevice(
          projectId, isDemoDevice ? 'Demo device' : 'FeroEase (Wi-Fi)');
      // 绑定关系立刻生效（设备批次不再跑仿真）；同步失败也保持绑定，
      // 否则一次超时就会让真实批次退回仿真、往真数据里掺假点。
      boundProjectId = projectId;
      await sync.attach(projectId);
      final result = await sync.sync();
      syncedCount = result.stored;
      status = sync.status ?? status;
      message = result.stored == 0
          ? 'Everything on the device is already in this batch.'
          : 'Synced ${result.stored} readings from the device.';
      // 绑定之后盯住这个批次的搅拌/加热：详情页一改就自动下发。
      _startObservingControl();
      await _pushControl(projectId);
    } on DeviceSyncException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = _describe(failure);
    } finally {
      syncing = false;
      notifyListeners();
      unawaited(refreshStatus());
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

  /// 只解除批次绑定（批次回到本地仿真），保持设备连接。
  Future<void> unbind() async {
    final projectId = boundProjectId;
    await _detach();
    if (projectId != null) controller.unbindDevice(projectId);
    notifyListeners();
  }

  // -- 控制状态自动同步 --

  /// 批次绑定期间盯住控制器：详情页改了搅拌/加热就自动补一次下发。
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

  Future<void> _pushControl(int projectId) async {
    final sync = _sync;
    if (sync == null || !isConnected) return;
    final control = _controlOf(projectId);
    if (control == null) return;
    _pushingControl = true;
    try {
      await sync.sendControl(
        stirrerOn: control.stirrerOn,
        stirrerRpm: control.stirrerRpm,
        heaterOn: control.heaterOn,
        targetTempC: control.targetTempC,
      );
      _lastPushedControl = control;
    } finally {
      _pushingControl = false;
    }
  }

  // -- 内部 --

  Future<void> _replaceClient(DeviceClient next) async {
    await _detach();
    await _connectionSub?.cancel();
    _connectionSub = null;
    final previous = _client;
    _client = next;
    if (previous != null && !identical(previous, next)) {
      await previous.close();
    }
    _sync = DeviceSyncService(client: next, sink: controller)
      ..onProgress = _onSyncProgress;
    _connectionSub = next.connectionStatus.listen(_onConnectionStatus);
  }

  Future<void> _detach() async {
    await _sync?.detach();
    _stopObservingControl();
    boundProjectId = null;
    syncedCount = 0;
  }

  void _onConnectionStatus(DeviceConnectionStatus next) {
    connection = next;
    if (next == DeviceConnectionStatus.disconnected ||
        next == DeviceConnectionStatus.failed) {
      // 断开时停掉同步，但**不解除批次绑定**：这是设备批次，
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
    if (failure is DeviceSyncException) return failure.message;
    if (failure is StateError) return failure.message;
    return 'Device error: $failure';
  }

  @override
  void dispose() {
    _stopObservingControl();
    unawaited(_connectionSub?.cancel());
    unawaited(_sync?.detach());
    final client = _client;
    _client = null;
    _sync = null;
    credentials = null;
    if (client != null) unawaited(client.close());
    super.dispose();
  }
}
