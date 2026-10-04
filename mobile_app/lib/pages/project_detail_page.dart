import 'dart:async';

import 'package:flutter/material.dart';

import '../models/control_state.dart';
import '../models/fermentation_project.dart';
import '../models/sensor_reading.dart';
import '../services/csv_export_service.dart';
import '../services/fermenter_controller.dart';
import '../services/harvest_detector.dart';
import '../utils/format.dart';
import '../widgets/live_chart.dart';
import '../widgets/sensor_card.dart';
import '../widgets/status_chip.dart';

class ProjectDetailPage extends StatefulWidget {
  const ProjectDetailPage({
    super.key,
    required this.controller,
    required this.projectId,
  });

  final FermenterController controller;
  final int projectId;

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage> {
  ChartMetric _metric = ChartMetric.turbidityOd;

  bool _stirrerOn = false;
  int _rpm = 200;
  bool _heaterOn = false;
  double _targetTempC = 30;
  bool _controlsInitialized = false;

  FermenterController get data => widget.controller;

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  // 在 build 中首次同步控件状态：直接赋值即可（同一趟 build 会用到），
  // 不能在 build 里调用 setState。
  void _initControls(FermentationProject project) {
    if (_controlsInitialized) return;
    _stirrerOn = project.stirrerOn;
    _rpm = project.stirrerRpm;
    _heaterOn = project.heaterOn;
    _targetTempC = project.targetTempC;
    _controlsInitialized = true;
  }

  Future<void> _persistControls() async {
    try {
      await data.setControl(
        widget.projectId,
        ControlState(
          stirrerOn: _stirrerOn,
          stirrerRpm: _rpm,
          heaterOn: _heaterOn,
          targetTempC: _targetTempC,
        ),
      );
    } catch (_) {
      _message('Control update failed.');
    }
  }

  Future<void> _togglePause(FermentationProject project) async {
    try {
      if (project.status == FermenterStatus.paused) {
        await data.resume(project.id);
      } else {
        await data.pause(project.id);
      }
    } catch (_) {
      _message('Action failed, please retry.');
    }
  }

  Future<void> _finish(FermentationProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark as harvested?'),
        content: const Text('The batch will be marked finished and stop '
            'recording. You can export the data afterwards.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Finish batch')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await data.finish(project.id);
      _message('Batch finished.');
    } catch (_) {
      _message('Action failed, please retry.');
    }
  }

  Future<void> _restart(FermentationProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart this batch?'),
        content: const Text('All readings will be cleared and the batch '
            'restarts from hour 0 with the same settings.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restart')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await data.restart(project.id);
      // 重启保留控制参数，不需要重新初始化。
      _message('Batch restarted.');
    } catch (_) {
      _message('Restart failed, please retry.');
    }
  }

  Future<void> _delete(FermentationProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this batch?'),
        content: Text('"${project.name}" and all readings will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await data.delete(project.id);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      _message('Delete failed, please retry.');
    }
  }

  Future<void> _export(
      BuildContext buttonContext, FermentationProject project) async {
    final readings = data.openReadings;
    if (readings.isEmpty) {
      _message('Nothing to export yet.');
      return;
    }
    final box = buttonContext.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    try {
      await CsvExportService().share(
          projectName: project.name,
          readings: List<SensorReading>.of(readings),
          origin: origin);
    } catch (_) {
      _message('Could not open the share sheet.');
    }
  }

  Future<void> _addManualReading(FermentationProject project) async {
    final result = await showDialog<_ManualReading>(
      context: context,
      builder: (context) => const _ManualReadingDialog(),
    );
    if (result == null || !mounted) return;
    try {
      await data.addManualReading(
        project.id,
        temperatureC: result.temperatureC,
        ph: result.ph,
        od: result.od,
        note: result.note,
      );
      _message('Reading added.');
    } catch (_) {
      _message('Could not save the reading.');
    }
  }

  void _editTargetTemp() async {
    final result = await showDialog<double>(
      context: context,
      builder: (context) => _TargetTempDialog(current: _targetTempC),
    );
    if (result == null || !mounted) return;
    setState(() => _targetTempC = result);
    await _persistControls();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: data,
      builder: (context, _) {
        final project = _projectOrNull();
        if (project == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
                child: data.loading
                    ? const CircularProgressIndicator()
                    : const Text('Batch not found.')),
          );
        }
        _initControls(project);
        return _buildPage(project);
      },
    );
  }

  FermentationProject? _projectOrNull() {
    for (final p in data.projects) {
      if (p.id == widget.projectId) return p;
    }
    return null;
  }

  Widget _buildPage(FermentationProject project) {
    final readings = data.openReadings;
    final verdict = data.openVerdict;
    final phase = classifyPhase(
      ods: readings.map((r) => r.od).toList(growable: false),
      verdict: verdict ?? const HarvestVerdict(
          triggered: false, peakOd: 0, odNow: 0, slope: 0, consecutiveDrop: 0),
      finished: project.status == FermenterStatus.finished,
    );
    final peakAt = _peakHour(readings);

    return Scaffold(
      appBar: AppBar(
        title: Text(project.name),
        actions: [
          if (project.status == FermenterStatus.paused ||
              project.isRunning)
            IconButton(
              onPressed: () => _togglePause(project),
              tooltip: project.status == FermenterStatus.paused
                  ? 'Resume'
                  : 'Pause',
              icon: Icon(project.status == FermenterStatus.paused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded),
            ),
          PopupMenuButton<String>(onSelected: (value) {
            switch (value) {
              case 'export':
                _export(context, project);
              case 'manual':
                _addManualReading(project);
              case 'finish':
                _finish(project);
              case 'restart':
                _restart(project);
              case 'delete':
                _delete(project);
            }
          }, itemBuilder: (context) => [
                const PopupMenuItem(
                    value: 'export',
                    child: ListTile(
                        leading: Icon(Icons.ios_share), title: Text('Export CSV'))),
                const PopupMenuItem(
                    value: 'manual',
                    child: ListTile(
                        leading: Icon(Icons.edit_note),
                        title: Text('Add manual reading'))),
                if (project.isRunning || project.status == FermenterStatus.finished)
                  const PopupMenuItem(
                      value: 'finish',
                      child: ListTile(
                          leading: Icon(Icons.check_circle_outline),
                          title: Text('Mark harvested / finish'))),
                const PopupMenuItem(
                    value: 'restart',
                    child: ListTile(
                        leading: Icon(Icons.replay), title: Text('Restart'))),
                const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'))),
              ]),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: RefreshIndicator(
              onRefresh: () => data.openProject(widget.projectId),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                children: [
                  _header(project, phase),
                  if (project.status == FermenterStatus.harvest) ...[
                    const SizedBox(height: 12),
                    _harvestCard(project),
                  ],
                  if (project.status == FermenterStatus.finished) ...[
                    const SizedBox(height: 12),
                    _finishedCard(project),
                  ],
                  const SizedBox(height: 16),
                  _metrics(project),
                  const SizedBox(height: 16),
                  _chartCard(project, readings, peakAt),
                  const SizedBox(height: 16),
                  _controlsCard(project),
                  const SizedBox(height: 16),
                  _statsCard(project, readings),
                  const SizedBox(height: 16),
                  _readingsCard(project, readings),
                  if (project.note != null && project.note!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _noteCard(project.note!),
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

  // -- 顶部 --

  Widget _header(FermentationProject project, FermentationPhase phase) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusChip(status: project.status),
            const SizedBox(width: 8),
            PhaseChip(phase: phase),
          ],
        ),
        const SizedBox(height: 10),
        if (project.strain != null && project.strain!.isNotEmpty)
          Text(project.strain!,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Text(
          'Elapsed ${simDurationLabel(project.simSeconds)} · '
          'batch #${project.id}',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _harvestCard(FermentationProject project) {
    final scheme = Theme.of(context).colorScheme;
    final verdict = data.openVerdict;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_active_rounded,
                    color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Harvest time!',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: scheme.onTertiaryContainer)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Turbidity has dropped rapidly from its peak '
              '(max OD600 ${number(verdict?.peakOd ?? project.peakOd ?? 0, 3)} → '
              'current ${number(verdict?.odNow ?? 0, 3)}). In the two-phase '
              'fermentation model, a sustained OD drop means the cells are '
              'lysing — this is the moment to harvest the protein.',
              style:
                  TextStyle(fontSize: 13, color: scheme.onTertiaryContainer),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => _finish(project),
                icon: const Icon(Icons.check),
                label: const Text('Mark as harvested'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _finishedCard(FermentationProject project) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                project.harvestAtSeconds != null
                    ? 'Batch finished ${simDurationLabel(project.harvestAtSeconds!)} '
                        'after start (harvest signal). Export the CSV to keep a record.'
                    : 'Batch finished. Export the CSV to keep a record.',
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -- 指标 --

  Widget _metrics(FermentationProject project) {
    final readings = data.openReadings;
    final current =
        readings.isEmpty ? null : readings.last;
    final previous = readings.length > 1 ? readings[readings.length - 2] : null;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 680 ? 3 : 1;
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        SensorCard(
          width: width,
          title: 'Temperature',
          unit: '°C',
          value: current == null ? '—' : number(current.temperatureC),
          subtitle: _deltaSubtitle(previous?.temperatureC, current?.temperatureC, 'targeted $targetLabel'),
          icon: Icons.thermostat_outlined,
          color: Colors.deepOrange.shade400,
        ),
        SensorCard(
          width: width,
          title: 'pH',
          unit: '',
          value: current == null ? '—' : number(current.ph),
          subtitle: _deltaSubtitle(previous?.ph, current?.ph, 'buffer drifts slowly'),
          icon: Icons.science_outlined,
          color: Colors.indigo.shade400,
        ),
        SensorCard(
          width: width,
          title: 'Turbidity',
          unit: 'OD600',
          value: current == null ? '—' : number(current.od, 3),
          subtitle: 'peak ${number(data.openVerdict?.peakOd ?? 0, 3)}',
          icon: Icons.bubble_chart_outlined,
          color: Colors.teal.shade600,
        ),
      ]);
    });
  }

  String get targetLabel => '${_targetTempC.round()} °C';

  String _deltaSubtitle(double? previous, double? current, String fallback) {
    if (previous == null || current == null) return fallback;
    final delta = current - previous;
    final arrow = delta > 0.001
        ? '▲'
        : delta < -0.001
            ? '▼'
            : '•';
    return '$arrow ${number(delta.abs(), 2)} vs last reading';
  }

  // -- 图表 --

  Widget _chartCard(
      FermentationProject project, List<SensorReading> readings, double? peakAt) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time course', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final metric in ChartMetric.values)
                ChoiceChip(
                  avatar: Icon(metric.icon, size: 16),
                  label: Text(metric.label),
                  selected: _metric == metric,
                  onSelected: (_) => setState(() => _metric = metric),
                ),
            ]),
            const SizedBox(height: 8),
            LiveChart(
              readings: readings,
              metric: _metric,
              peakAtHours: peakAt,
              harvestAtHours: project.harvestAtSeconds == null
                  ? null
                  : project.harvestAtSeconds! / 3600,
            ),
            const SizedBox(height: 4),
            Text(
              'X axis = simulated hours since start. '
              'Manual readings are included too.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  double? _peakHour(List<SensorReading> readings) {
    if (readings.isEmpty) return null;
    var peak = readings.first;
    for (final r in readings) {
      if (r.od > peak.od) peak = r;
    }
    return peak.simHours;
  }

  // -- 控制 --

  Widget _controlsCard(FermentationProject project) {
    final readOnly = project.status == FermenterStatus.finished;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.tune, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Controls',
                      style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    'Simulated device',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stirrer'),
              subtitle: _stirrerOn
                  ? Text('$_rpm rpm (PWM)')
                  : const Text('Off — culture may sediment'),
              value: _stirrerOn,
              onChanged: readOnly
                  ? null
                  : (value) {
                      setState(() => _stirrerOn = value);
                      unawaited(_persistControls());
                    },
            ),
            if (_stirrerOn)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
                child: Row(
                  children: [
                    Text('${ControlState.minRpm}',
                        style: const TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _rpm.toDouble().clamp(
                            ControlState.minRpm.toDouble(),
                            ControlState.maxRpm.toDouble()).toDouble(),
                        min: ControlState.minRpm.toDouble(),
                        max: ControlState.maxRpm.toDouble(),
                        divisions: 8,
                        label: '$_rpm rpm',
                        onChanged: readOnly
                            ? null
                            : (v) => setState(() => _rpm = v.round()),
                        onChangeEnd: (_) => unawaited(_persistControls()),
                      ),
                    ),
                    Text('${ControlState.maxRpm}',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            const Divider(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Heater'),
              subtitle: _heaterOn
                  ? Text('Heating toward ${_targetTempC.round()} °C')
                  : const Text('Off — cooling to room temperature'),
              value: _heaterOn,
              onChanged: readOnly
                  ? null
                  : (value) {
                      setState(() => _heaterOn = value);
                      unawaited(_persistControls());
                    },
            ),
            if (_heaterOn)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.thermostat),
                title: const Text('Target temperature'),
                trailing: Text('${_targetTempC.round()} °C',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                onTap: readOnly ? null : _editTargetTemp,
              ),
          ],
        ),
      ),
    );
  }

  // -- 统计 --

  Widget _statsCard(
      FermentationProject project, List<SensorReading> readings) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String)>[
      ('Readings', '${readings.length}'),
      ('Peak OD600', number(project.peakOd ?? data.openVerdict?.peakOd ?? 0, 3)),
      ('Harvest signal', project.harvestAtSeconds == null
          ? '—'
          : simDurationLabel(project.harvestAtSeconds!)),
      ('Last reading', readings.isEmpty
          ? '—'
          : '${readings.last.recordedAt.toLocal().hour.toString().padLeft(2, '0')}:'
              '${readings.last.recordedAt.toLocal().minute.toString().padLeft(2, '0')}'),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Stats', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(row.$1,
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurfaceVariant))),
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

  // -- 最近读数 --

  Widget _readingsCard(
      FermentationProject project, List<SensorReading> readings) {
    final scheme = Theme.of(context).colorScheme;
    final recent = readings.length > 6 ? readings.sublist(readings.length - 6) : readings;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Recent readings', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: project.status == FermenterStatus.finished
                      ? null
                      : () => _addManualReading(project),
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('Add manual reading'),
                ),
              ],
            ),
            if (recent.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No readings yet — the simulator runs continuously.',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              )
            else
              Column(
                children: [
                  _row(['sim time', 'T °C', 'pH', 'OD600'], bold: true),
                  const Divider(height: 8),
                  for (final r in recent)
                    _row([
                      simDurationLabel(r.simSeconds),
                      number(r.temperatureC),
                      number(r.ph),
                      number(r.od, 3),
                    ]),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(List<String> cells, {bool bold = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                cells[i],
                textAlign: i == 0 ? TextAlign.start : TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  color: bold ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _noteCard(String note) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Notes', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(note, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

// -- 手动读数对话框 --

class _ManualReading {
  const _ManualReading({
    required this.temperatureC,
    required this.ph,
    required this.od,
    this.note,
  });

  final double temperatureC;
  final double ph;
  final double od;
  final String? note;
}

class _ManualReadingDialog extends StatefulWidget {
  const _ManualReadingDialog();

  @override
  State<_ManualReadingDialog> createState() => _ManualReadingDialogState();
}

class _ManualReadingDialogState extends State<_ManualReadingDialog> {
  final _formKey = GlobalKey<FormState>();
  final _temp = TextEditingController(text: '30.0');
  final _ph = TextEditingController(text: '7.0');
  final _od = TextEditingController(text: '0.5');
  final _note = TextEditingController();

  @override
  void dispose() {
    _temp.dispose();
    _ph.dispose();
    _od.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_ManualReading(
      temperatureC: double.parse(_temp.text),
      ph: double.parse(_ph.text),
      od: double.parse(_od.text),
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add manual reading'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _temp,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Temperature (°C)'),
                validator: (v) => _valid(v, 0, 60) ? null : '0 – 60 °C',
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _ph,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'pH'),
                validator: (v) => _valid(v, 0, 14) ? null : '0 – 14',
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _od,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Turbidity (OD600)'),
                validator: (v) => _valid(v, 0, 10) ? null : '0 – 10',
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }

  bool _valid(String? value, double min, double max) {
    final parsed = double.tryParse(value ?? '');
    return parsed != null && parsed >= min && parsed <= max;
  }
}

class _TargetTempDialog extends StatefulWidget {
  const _TargetTempDialog({required this.current});

  final double current;

  @override
  State<_TargetTempDialog> createState() => _TargetTempDialogState();
}

class _TargetTempDialogState extends State<_TargetTempDialog> {
  late double _preview = widget.current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Target temperature'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${_preview.round()} °C',
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          Slider(
            value: _preview,
            min: 20,
            max: 42,
            divisions: 22,
            label: '${_preview.round()} °C',
            onChanged: (v) => setState(() => _preview = v),
          ),
          Text('Used while the heater is on.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _preview),
            child: const Text('Save')),
      ],
    );
  }
}