import 'package:flutter/material.dart';

import '../database/fermenter_repository.dart';
import '../services/fermenter_controller.dart';

class NewProjectPage extends StatefulWidget {
  const NewProjectPage({super.key, required this.controller});

  final FermenterController controller;

  @override
  State<NewProjectPage> createState() => _NewProjectPageState();
}

class _NewProjectPageState extends State<NewProjectPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _strain = TextEditingController();
  final _note = TextEditingController();
  double _targetTempC = 30;
  int _timeScale = 60; // 1 真实秒 = 60 仿真秒
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
    setState(() => _submitting = true);
    try {
      await widget.controller.createProject(ProjectDraft(
        name: _name.text,
        strain: _strain.text.trim().isEmpty ? null : _strain.text.trim(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        targetTempC: _targetTempC,
        timeScale: _timeScale,
      ));
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
    final scheme = Theme.of(context).colorScheme;
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
                  Text('Simulation speed',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 30, label: Text('30×')),
                      ButtonSegment(value: 60, label: Text('60×')),
                      ButtonSegment(value: 120, label: Text('120×')),
                    ],
                    selected: {_timeScale},
                    onSelectionChanged: (value) =>
                        setState(() => _timeScale = value.single),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Simulated time runs $_timeScale× faster than real time, '
                    'so a full 18 h run takes about '
                    '${(18 * 3600 / _timeScale).round() ~/ 60} min.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
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
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Start batch'),
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
              'Stirring and heating are simulated until the hardware is '
              'connected.',
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}