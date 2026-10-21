import 'package:flutter/material.dart';

import '../database/fermenter_repository.dart';
import '../services/ble_device_manager.dart';
import '../services/fermenter_controller.dart';

/// 新建批次：只在设备已连接时可用，批次创建后立即绑定设备并同步 flash 日志。
///
/// 这里刻意不提供仿真：没有硬件时的演示走首页的「Load sample data」。
class NewProjectPage extends StatefulWidget {
  const NewProjectPage({
    super.key,
    required this.controller,
    required this.device,
  });

  final FermenterController controller;
  final BleDeviceManager device;

  @override
  State<NewProjectPage> createState() => _NewProjectPageState();
}

class _NewProjectPageState extends State<NewProjectPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _strain = TextEditingController();
  final _note = TextEditingController();
  double _targetTempC = 30;
  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _strain.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final device = widget.device;
    if (!device.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Connect FeroEase before starting a batch.')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final id = await widget.controller.createProject(
        ProjectDraft(
          name: _name.text,
          strain: _strain.text.trim().isEmpty ? null : _strain.text.trim(),
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          targetTempC: _targetTempC,
          timeScale: 1,
        ),
        deviceLabel: device.connectedDevice?.displayName ?? 'FeroEase',
      );
      // 绑定 + 同步：绑定前不会有仿真点，同步失败也保持绑定（数据还在设备上）。
      await device.syncToProject(id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not start the batch: $e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New batch')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  TextFormField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Batch name',
                      hintText: 'e.g. Batch A (lysis strain)',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                            ? 'Enter a name for this batch'
                            : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _strain,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Strain / construct (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _note,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Target temperature',
                      style: Theme.of(context).textTheme.titleSmall),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: _targetTempC,
                          min: 20,
                          max: 42,
                          divisions: 22,
                          label: '${_targetTempC.round()} °C',
                          onChanged: (v) => setState(() => _targetTempC = v),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text('${_targetTempC.round()} °C',
                            textAlign: TextAlign.right,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Device',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  _deviceCard(),
                  const SizedBox(height: 24),
                  _infoCard(),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _submitting
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _submitting ? null : _submit,
                          icon: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.play_arrow_rounded),
                          label: Text(
                              _submitting ? 'Syncing…' : 'Start batch'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _deviceCard() {
    final device = widget.device;
    final scheme = Theme.of(context).colorScheme;
    final name = device.connectedDevice?.displayName;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(device.isConnected
              ? Icons.bluetooth_connected
              : Icons.bluetooth_disabled),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              device.isConnected
                  ? 'Readings come from ${name ?? 'the connected device'}. '
                      'Records already in its flash log are pulled in now; '
                      'new samples keep arriving while the app is open.'
                  : 'No device connected. Connect FeroEase from the device '
                      'page before starting a batch.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Two-phase fermentation: turbidity (OD600) rises while the cells '
              'grow, then falls sharply once they lyse. The app watches for '
              'that sustained drop and raises the harvest alert automatically. '
              'Every point on the curve is measured by the device — nothing is '
              'simulated here.',
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}