import 'package:flutter/material.dart';

import '../models/fermentation_project.dart';
import '../services/fermenter_controller.dart';
import '../utils/format.dart';
import '../widgets/status_chip.dart';
import 'new_project_page.dart';
import 'project_detail_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final FermenterController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loadingSample = false;

  FermenterController get data => widget.controller;

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _openNewProject() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => NewProjectPage(controller: data)),
    );
    if (created == true && mounted) _message('Batch started.');
  }

  /// 生成一个跑完整周期的演示批次，并直接打开它，方便一次性检查
  /// 曲线、收获告警、统计与导出在无硬件情况下的表现。
  Future<void> _loadSampleData() async {
    setState(() => _loadingSample = true);
    int? id;
    try {
      id = await data.loadSampleBatch();
    } catch (_) {
      id = null;
    }
    if (!mounted) return;
    setState(() => _loadingSample = false);
    if (id == null) {
      _message('Could not load sample data.');
      return;
    }
    _message('Sample batch loaded.');
    final projectId = id;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
          builder: (_) =>
              ProjectDetailPage(controller: data, projectId: projectId)),
    );
    if (mounted) await data.refresh();
  }

  Future<void> _openProject(FermentationProject project) async {
    await data.selectProject(project.id);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
          builder: (_) => ProjectDetailPage(controller: data, projectId: project.id)),
    );
    if (mounted) await data.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: data,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Fermenter'),
          actions: [
            IconButton(
                onPressed: data.loading ? null : data.refresh,
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh)),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _openNewProject,
          icon: const Icon(Icons.add),
          label: const Text('New Batch'),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                children: [
                  if (data.loading)
                    const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: data.error != null
                        ? _errorView()
                        : RefreshIndicator(
                            onRefresh: data.refresh,
                            child: data.projects.isEmpty
                                ? _emptyView()
                                : _projectList(),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.storage_outlined, size: 40),
            const SizedBox(height: 12),
            Text(data.error!),
            TextButton(onPressed: data.refresh, child: const Text('Retry')),
          ]),
        ),
      );

  Widget _emptyView() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 48),
          const Icon(Icons.biotech_outlined, size: 64),
          const SizedBox(height: 16),
          const Text('No fermentations yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Tap "New Batch" to start monitoring\n'
            'temperature, pH and turbidity — the app will tell you\n'
            'when the turbidity drop means it is time to harvest.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _sampleNote(),
        ],
      );

  Widget _projectList() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        children: [
          _sampleNote(),
          const SizedBox(height: 12),
          for (final project in data.projects) ...[
            _projectCard(project),
            const SizedBox(height: 10),
          ],
        ],
      );

  Widget _projectCard(FermentationProject project) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openProject(project),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusChip(status: project.status),
                ],
              ),
              if (project.strain != null && project.strain!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(project.strain!,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  _miniMetric('Temp', '${project.lastTemperatureC == null ? '—' : number(project.lastTemperatureC!)} °C'),
                  const SizedBox(width: 16),
                  _miniMetric(
                      'pH', project.lastPh == null ? '—' : number(project.lastPh!)),
                  const SizedBox(width: 16),
                  _miniMetric('OD600',
                      project.lastOd == null ? '—' : number(project.lastOd!, 3)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.timelapse_rounded,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(simDurationLabel(project.simSeconds),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniMetric(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Text(value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ],
      );

  Widget _sampleNote() =>
      _SimulationNote(busy: _loadingSample, onLoadSample: _loadSampleData);
}

/// 无硬件阶段的提示条 + 「载入样例数据」入口。
class _SimulationNote extends StatelessWidget {
  const _SimulationNote({required this.busy, required this.onLoadSample});

  final bool busy;
  final VoidCallback onLoadSample;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_outlined,
                  size: 20, color: scheme.onSecondaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Simulated device for now — the ESP32 hardware interface will be plugged in next.',
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: busy ? null : onLoadSample,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome, size: 18),
              label: Text(
                  busy ? 'Generating sample data…' : 'Load sample data'),
            ),
          ),
        ],
      ),
    );
  }
}