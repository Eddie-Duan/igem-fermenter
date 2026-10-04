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
  bool _working = false;

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

  Future<void> _openProject(FermentationProject project) async {
    await data.openProject(project.id);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
          builder: (_) => ProjectDetailPage(controller: data, projectId: project.id)),
    );
    if (mounted) await data.refresh();
  }

  Future<void> _pauseOrResume(FermentationProject project) async {
    setState(() => _working = true);
    try {
      if (project.status == FermenterStatus.paused) {
        await data.resume(project.id);
      } else if (project.status == FermenterStatus.active ||
          project.status == FermenterStatus.harvest) {
        await data.pause(project.id);
      }
    } catch (_) {
      _message('Action failed, please retry.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _delete(FermentationProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this batch?'),
        content: Text('"${project.name}" and all its readings will be removed permanently.'),
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
      _message('Batch deleted.');
    } catch (_) {
      _message('Delete failed, please retry.');
    }
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
        children: const [
          SizedBox(height: 48),
          Icon(Icons.biotech_outlined, size: 64),
          SizedBox(height: 16),
          Text('No fermentations yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text(
            'Tap "New Batch" to start monitoring\n'
            'temperature, pH and turbidity — the app will tell you\n'
            'when the turbidity drop means it is time to harvest.',
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 32),
          _SimulationNote(),
        ],
      );

  Widget _projectList() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        children: [
          const _SimulationNote(),
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
                  _miniMetric('pH', '${project.lastPh == null ? '—' : number(project.lastPh!)}'),
                  const SizedBox(width: 16),
                  _miniMetric('OD600', '${project.lastOd == null ? '—' : number(project.lastOd!, 3)}'),
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
}

/// 无硬件阶段的提示条。
class _SimulationNote extends StatelessWidget {
  const _SimulationNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.memory_outlined, size: 20, color: scheme.onSecondaryContainer),
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
    );
  }
}