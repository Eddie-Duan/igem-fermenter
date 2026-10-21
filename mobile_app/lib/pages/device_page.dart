import 'package:flutter/material.dart';

import '../device/device_client.dart';
import '../models/control_state.dart';
import '../services/device_manager.dart';
import '../services/fermenter_controller.dart';
import '../utils/format.dart';

/// 连接 ESP32-S3：填地址 → 连接 → 选批次同步 → 下发控制。
///
/// 设备始终开着一个配置热点（`192.168.4.1`），也可以先在设备网页里让它
/// 连上路由器，再改用路由器地址。密码见设备串口日志。
/// 没有硬件时用「演示设备」走完全同一条链路。
class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.controller, required this.manager});

  final FermenterController controller;
  final DeviceManager manager;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final _address = TextEditingController(text: '192.168.4.1');
  final _user = TextEditingController(text: 'admin');
  final _password = TextEditingController();
  final _target = TextEditingController(text: '30');

  int? _selectedProjectId;
  bool _busy = false;
  bool _heater = false;
  DeviceManager get manager => widget.manager;

  @override
  void dispose() {
    _address.dispose();
    _user.dispose();
    _password.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Device')),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _statusCard(),
                  const SizedBox(height: 16),
                  _connectionCard(),
                  const SizedBox(height: 16),
                  if (manager.isConnected) ...[
                    _deviceInfoCard(),
                    const SizedBox(height: 16),
                    _controlCard(),
                    const SizedBox(height: 16),
                    _syncCard(),
                  ] else
                    _demoCard(),
                  if (manager.error != null) ...[
                    const SizedBox(height: 16),
                    _noticeCard(manager.error!, isError: true),
                  ],
                  if (manager.message != null) ...[
                    const SizedBox(height: 16),
                    _noticeCard(manager.message!, isError: false),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -- 状态 --

  Widget _statusCard() {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (manager.connection) {
      DeviceConnectionStatus.connected => (
          Icons.wifi,
          manager.address ?? 'Connected',
          scheme.primary,
        ),
      DeviceConnectionStatus.connecting => (
          Icons.wifi_find,
          'Connecting…',
          scheme.onSurfaceVariant,
        ),
      DeviceConnectionStatus.failed => (
          Icons.wifi_off,
          'Connection failed',
          scheme.error,
        ),
      DeviceConnectionStatus.disconnected => (
          Icons.wifi_off,
          'No device connected',
          scheme.onSurfaceVariant,
        ),
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                    manager.isConnected
                        ? (manager.isDemoDevice
                            ? 'Demo device — the whole link is simulated.'
                            : 'Connected to the fermenter over Wi-Fi.')
                        : 'Readings keep coming from the built-in simulator '
                            'until a device is connected.',
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (manager.isConnected)
              TextButton(
                onPressed: _busy ? null : _disconnect,
                child: const Text('Disconnect'),
              ),
          ],
        ),
      ),
    );
  }

  // -- 连接 --

  Widget _connectionCard() {
    final scheme = Theme.of(context).colorScheme;
    final connected = manager.isConnected;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect over Wi-Fi',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Join the ESP32 hotspot on this phone (192.168.4.1), or use the '
              'device web page to put both on the same router. The Web/hotspot '
              'password is printed in the device serial log at boot.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _address,
              enabled: !connected,
              decoration: const InputDecoration(
                  labelText: 'Device IP address',
                  hintText: '192.168.4.1',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  enabled: !connected,
                  decoration: const InputDecoration(
                      labelText: 'User',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _password,
                  enabled: !connected,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Web password',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi, size: 18),
                label: Text(connected ? 'Reconnect' : 'Connect'),
              ),
              if (connected) ...[
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : manager.refreshStatus,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  // -- 设备信息 --

  Widget _deviceInfoCard() {
    final scheme = Theme.of(context).colorScheme;
    final status = manager.status;
    final range = manager.logRange;
    final rows = <(String, String)>[
      ('Firmware', status?.firmwareLabel ?? '—'),
      ('Device ID', status?.deviceId ?? '—'),
      ('Transport', 'Wi-Fi (HTTP)'),
      (
        'Router IP',
        (status == null || status.stationIp.isEmpty)
            ? 'not connected'
            : status.stationIp
      ),
      (
        'Log',
        range == null
            ? '—'
            : 'seq ${range.oldest}…${range.next} (${range.count} readings)'
      ),
      ('Record period', '${status?.sampleIntervalS ?? 120} s'),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(row.$1,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                    Text(row.$2,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // -- 控制 --

  Widget _controlCard() {
    final scheme = Theme.of(context).colorScheme;
    final status = manager.status;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Controls', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Bind the device to a batch and its heater/stirrer settings are '
              'pushed automatically; changing them in the batch page also '
              'reaches the device. Use this row for a one-off change.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _target,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Target °C',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto heat'),
                  subtitle: Text(
                    status?.stirrerSupported == true
                        ? 'Stirrer output is wired on this build'
                        : 'Stirrer output is not wired on this build',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  value: _heater,
                  onChanged: (value) => setState(() => _heater = value),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy ? null : _sendControls,
                icon: const Icon(Icons.send, size: 18),
                label: const Text('Send to device'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -- 同步 --

  Widget _syncCard() {
    final scheme = Theme.of(context).colorScheme;
    final projects = widget.controller.projects;
    final boundId = manager.boundProjectId;
    final bound =
        boundId == null ? null : widget.controller.projectById(boundId);
    final current = _selectedProjectId ??
        boundId ??
        (projects.isEmpty ? null : projects.first.id);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sync the device log',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Pick the batch these readings belong to. Records already on the '
              'device are imported once; the device only reclaims them after '
              'the app confirms they are stored.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (projects.isEmpty)
              Text('Create a batch first.',
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else ...[
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Batch',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                child: DropdownButton<int>(
                  value: current,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  onChanged: manager.syncing
                      ? null
                      : (value) => setState(() => _selectedProjectId = value),
                  items: [
                    for (final project in projects)
                      DropdownMenuItem(
                        value: project.id,
                        child: Text(project.name,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (manager.syncing)
                Row(
                  children: [
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text('Syncing… ${manager.syncedCount} readings',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                )
              else
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: current == null
                          ? null
                          : () => manager.syncToProject(current),
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('Sync to batch'),
                    ),
                    const SizedBox(width: 10),
                    TextButton.icon(
                      onPressed: current == null
                          ? null
                          : () => manager.pushControl(current),
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('Send controls'),
                    ),
                  ],
                ),
            ],
            if (bound != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.link, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Bound to "${bound.name}" — '
                      '${simDurationLabel(bound.simSeconds)} recorded.',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton(
                    onPressed: () => manager.unbind(),
                    child: const Text('Unbind'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _demoCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No hardware at hand?',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'The demo device follows the same connect → bind → sync → live '
              'path, so the rest of the app behaves exactly like it does with '
              'real hardware.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: manager.connectDemoDevice,
              icon: const Icon(Icons.smart_toy_outlined, size: 18),
              label: const Text('Use a demo device'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noticeCard(String text, {required bool isError}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: isError ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(isError ? Icons.error_outline : Icons.check_circle_outline,
                size: 20,
                color: isError
                    ? scheme.onErrorContainer
                    : scheme.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 13,
                      color: isError
                          ? scheme.onErrorContainer
                          : scheme.onSecondaryContainer)),
            ),
          ],
        ),
      ),
    );
  }

  // -- 动作 --

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      await manager.connect(
        address: _address.text,
        username: _user.text.trim().isEmpty ? 'admin' : _user.text.trim(),
        password: _password.text,
      );
      final status = manager.status;
      if (status != null && mounted) {
        setState(() {
          _target.text = status.targetTempC.toStringAsFixed(1);
          _heater = status.heaterEnabled;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await manager.disconnect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendControls() async {
    final boundId = manager.boundProjectId;
    if (boundId == null) {
      setState(() {
        manager.error = 'Bind the device to a batch first.';
      });
      return;
    }
    final project = widget.controller.projectById(boundId);
    if (project == null) return;
    setState(() => _busy = true);
    try {
      await widget.controller.setControl(
        boundId,
        ControlState(
          stirrerOn: project.stirrerOn,
          stirrerRpm: project.stirrerRpm,
          heaterOn: _heater,
          targetTempC: double.tryParse(_target.text) ?? project.targetTempC,
        ),
      );
      await manager.pushControl(boundId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
