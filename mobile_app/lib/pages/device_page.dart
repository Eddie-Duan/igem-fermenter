import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/ble_client.dart';
import '../services/ble_device_manager.dart';
import '../services/fermenter_controller.dart';
import '../services/wifi_device_client.dart';
import '../utils/format.dart';

/// 连接 ESP32-S3：扫描 → 连接 → 选批次同步 → 下发控制。
///
/// 没有硬件时用「演示设备」（[BleDeviceManager.connectDemoDevice]）走完全同一条链路。
class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.controller, required this.manager});

  final FermenterController controller;
  final BleDeviceManager manager;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  int? _selectedProjectId;
  final _wifiClient = WifiDeviceClient();
  final _wifiAddress = TextEditingController(text: '192.168.4.1');
  final _wifiUser = TextEditingController(text: 'admin');
  final _wifiPassword = TextEditingController();
  Map<String, dynamic>? _wifiStatus;
  bool _wifiBusy = false;
  String? _wifiError;
  Timer? _wifiPoller;
  bool _wifiPolling = false;
  double _wifiTarget = 30;
  bool _wifiHeater = false;

  BleDeviceManager get manager => widget.manager;

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
                  _wifiCard(),
                  const SizedBox(height: 16),
                  if (!manager.isConnected) ...[
                    _scanCard(),
                    const SizedBox(height: 16),
                    _deviceList(),
                  ] else ...[
                    _deviceInfoCard(),
                    const SizedBox(height: 16),
                    _syncCard(),
                  ],
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

  Widget _wifiCard() {
    final scheme = Theme.of(context).colorScheme;
    final status = _wifiStatus;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Connect over Wi-Fi', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text('First connect this phone to the ESP32 hotspot in Wi-Fi settings or put both on the same router. The hotspot address is 192.168.4.1; the password is printed in the device serial log.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          TextField(controller: _wifiAddress, decoration: const InputDecoration(labelText: 'Device IP address', hintText: '192.168.4.1', border: OutlineInputBorder(), isDense: true)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _wifiUser, decoration: const InputDecoration(labelText: 'User', border: OutlineInputBorder(), isDense: true))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _wifiPassword, obscureText: true, decoration: const InputDecoration(labelText: 'Web password', border: OutlineInputBorder(), isDense: true))),
          ]),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: _wifiBusy ? null : _connectWifi,
            icon: _wifiBusy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi, size: 18),
            label: Text(_wifiStatus == null ? 'Connect' : 'Refresh status')),
          if (_wifiError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_wifiError!, style: TextStyle(color: scheme.error))),
          if (status != null) ...[
            const Divider(height: 22),
            Text('Wi-Fi connected · ${status['staIp'] ?? status['apIp'] ?? _wifiAddress.text}', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('Temperature ${status['tempC'] ?? '—'} °C · pH ${status['ph'] ?? '—'} · optical ${status['odProxy'] ?? '—'}'),
            Text('Heater ${status['heaterOn'] == true ? 'on' : 'off'} · alarm ${status['alarm'] == true ? 'active' : 'clear'}'),
            const SizedBox(height: 8),
            Row(children: [
              SizedBox(width: 120, child: TextField(key: ValueKey(_wifiTarget), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Target °C', border: OutlineInputBorder(), isDense: true), onChanged: (v) => _wifiTarget = double.tryParse(v) ?? _wifiTarget)),
              const SizedBox(width: 10),
              Expanded(child: SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Auto heat'), value: _wifiHeater, onChanged: (v) => setState(() => _wifiHeater = v))),
              IconButton(tooltip: 'Send Wi-Fi controls', onPressed: _wifiBusy ? null : _sendWifiControl, icon: const Icon(Icons.send)),
            ]),
          ],
        ]),
      ),
    );
  }

  Future<void> _connectWifi() async {
    setState(() { _wifiBusy = true; _wifiError = null; });
    try {
      final status = await _wifiClient.status(address: _wifiAddress.text, username: _wifiUser.text, password: _wifiPassword.text);
      if (!mounted) return;
      setState(() { _wifiStatus = status; _wifiTarget = (status['targetTempC'] as num?)?.toDouble() ?? 30; _wifiHeater = status['heaterEnabled'] == true; });
      _wifiPoller ??= Timer.periodic(const Duration(seconds: 3), (_) => _pollWifi());
    } catch (e) { if (mounted) setState(() => _wifiError = e.toString()); }
    finally { if (mounted) setState(() => _wifiBusy = false); }
  }

  Future<void> _pollWifi() async {
    if (_wifiBusy || _wifiPolling || !mounted) return;
    _wifiPolling = true;
    try {
      final status = await _wifiClient.status(address: _wifiAddress.text, username: _wifiUser.text, password: _wifiPassword.text);
      if (mounted) setState(() => _wifiStatus = status);
    } catch (e) {
      if (mounted) setState(() { _wifiPoller?.cancel(); _wifiPoller = null; _wifiStatus = null; _wifiError = e.toString(); });
    } finally {
      _wifiPolling = false;
    }
  }

  Future<void> _sendWifiControl() async {
    setState(() { _wifiBusy = true; _wifiError = null; });
    try {
      await _wifiClient.setControl(address: _wifiAddress.text, username: _wifiUser.text, password: _wifiPassword.text, targetTempC: _wifiTarget, heaterEnabled: _wifiHeater);
      await _connectWifi();
    } catch (e) { if (mounted) setState(() => _wifiError = e.toString()); }
    finally { if (mounted) setState(() => _wifiBusy = false); }
  }

  @override
  void dispose() {
    _wifiPoller?.cancel();
    _wifiClient.close();
    _wifiAddress.dispose();
    _wifiUser.dispose();
    _wifiPassword.dispose();
    super.dispose();
  }

  // -- 连接状态 --

  Widget _statusCard() {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (manager.connection) {
      BleConnectionStatus.connected => (
          Icons.bluetooth_connected,
          manager.connectedDevice?.displayName ?? 'Connected',
          scheme.primary,
        ),
      BleConnectionStatus.connecting => (
          Icons.bluetooth_searching,
          'Connecting…',
          scheme.onSurfaceVariant,
        ),
      BleConnectionStatus.failed => (
          Icons.bluetooth_disabled,
          'Connection failed',
          scheme.error,
        ),
      BleConnectionStatus.disconnected => (
          Icons.bluetooth,
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
                            : 'Connected to the fermenter over BLE.')
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
                onPressed: () => manager.disconnect(),
                child: const Text('Disconnect'),
              ),
          ],
        ),
      ),
    );
  }

  // -- 扫描 --

  Widget _scanCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pair the fermenter',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Power the ESP32-S3, then scan. The device must advertise the '
              'service UUID from docs/ble-gatt.md.',
              style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: manager.scanning
                      ? () => manager.stopScan()
                      : () => manager.startScan(),
                  icon: manager.scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 18),
                  label: Text(manager.scanning ? 'Stop scan' : 'Scan'),
                ),
                TextButton.icon(
                  onPressed: manager.scanning
                      ? null
                      : () => manager.connectDemoDevice(),
                  icon: const Icon(Icons.smart_toy_outlined, size: 18),
                  label: const Text('Use a demo device'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceList() {
    final scheme = Theme.of(context).colorScheme;
    if (manager.devices.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Center(
            child: Text(
              manager.scanning ? 'Scanning…' : 'No device found yet.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final device in manager.devices)
            ListTile(
              leading: const Icon(Icons.memory_outlined),
              title: Text(device.displayName),
              subtitle: Text('${device.id} · ${device.rssi} dBm',
                  style: const TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => manager.connect(device),
            ),
        ],
      ),
    );
  }

  // -- 已连接 --

  Widget _deviceInfoCard() {
    final scheme = Theme.of(context).colorScheme;
    final info = manager.deviceInfo;
    final log = manager.logStatus;
    final rows = <(String, String)>[
      ('Firmware', info?.firmwareLabel ?? '—'),
      ('Device ID', info?.mac ?? manager.connectedDevice?.id ?? '—'),
      ('Device battery', info == null ? '—' : '${info.batteryMv} mV'),
      ('Unsynchronised', log == null ? '—' : '${log.count} readings'),
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

  Widget _syncCard() {
    final scheme = Theme.of(context).colorScheme;
    final projects = widget.controller.projects;
    final boundId = manager.boundProjectId;
    final bound =
        boundId == null ? null : widget.controller.projectById(boundId);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sync the flash log', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Pick the batch these readings belong to. Records already on the '
              'device are imported once; new samples keep arriving live.',
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
                  value: _selectedProjectId ??
                      boundId ??
                      projects.first.id,
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
                      onPressed: () => manager.syncToProject(_selectedProjectId ??
                          boundId ??
                          projects.first.id),
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('Sync to batch'),
                    ),
                    const SizedBox(width: 10),
                    TextButton.icon(
                      onPressed: () => manager.pushControl(boundId ??
                          _selectedProjectId ??
                          projects.first.id),
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
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
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
}
