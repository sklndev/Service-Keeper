import 'package:flutter/material.dart';
import '../models/monitored_service.dart';

class ServiceDetailScreen extends StatefulWidget {
  final MonitoredService service;
  final bool globalIntervalEnabled;
  final int globalIntervalMinutes;

  const ServiceDetailScreen({
    super.key,
    required this.service,
    this.globalIntervalEnabled = true,
    this.globalIntervalMinutes = 15,
  });

  @override
  State<ServiceDetailScreen> createState() => _ServiceDetailScreenState();
}

class _ServiceDetailScreenState extends State<ServiceDetailScreen> {
  int? _customIntervalMinutes;

  static const _presets = [
    (label: '5 minutes', minutes: 5),
    (label: '10 minutes', minutes: 10),
    (label: '15 minutes', minutes: 15),
    (label: '30 minutes', minutes: 30),
    (label: '1 hour', minutes: 60),
    (label: '2 hours', minutes: 120),
    (label: '4 hours', minutes: 240),
  ];

  @override
  void initState() {
    super.initState();
    _customIntervalMinutes = widget.service.customIntervalMinutes;
  }

  int get _effectiveMinutes => _customIntervalMinutes ?? widget.globalIntervalMinutes;

  MonitoredService _buildUpdatedService() {
    final effectiveMinutes = _customIntervalMinutes ?? widget.globalIntervalMinutes;
    return widget.service.copyWith(
      customIntervalMinutes: _customIntervalMinutes,
      intervalMinutes: effectiveMinutes,
    );
  }

  bool get _hasChanges =>
      _customIntervalMinutes != widget.service.customIntervalMinutes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<MonitoredService>(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _hasChanges) Navigator.pop(context, _buildUpdatedService());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Configure Service'),
          actions: [
            TextButton(
              onPressed: _save,
              child: const Text('Done'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    color: theme.colorScheme.onSurfaceVariant, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Changes are saved automatically when you go back. Tap Done to close now.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Service Info',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _infoRow('Label', widget.service.displayLabel),
                  _infoRow('Package', widget.service.packageName),
                  _infoRow('Service class', widget.service.serviceClass),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Check interval',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'How often the app verifies the service is running and restarts it if needed.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (!widget.globalIntervalEnabled)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule_outlined,
                      color: theme.colorScheme.onSurfaceVariant, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Interval checking is disabled globally. Enable it in Settings to use scheduled checks.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          RadioGroup<int>(
            groupValue: _customIntervalMinutes ?? 0,
            onChanged: (value) {
              if (!widget.globalIntervalEnabled || value == null) return;
              setState(() => _customIntervalMinutes = value == 0 ? null : value);
            },
            child: Column(
              children: [
                RadioListTile<int>(
                  title: Text('Default value (${widget.globalIntervalMinutes} min)'),
                  subtitle: Text(widget.globalIntervalEnabled
                      ? 'Use the value set in Settings'
                      : 'Disabled globally',
                          style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                        ),
                  value: 0,
                  enabled: widget.globalIntervalEnabled,
                ),
                ..._presets.map((p) => RadioListTile<int>(
                      title: Text(p.label),
                      subtitle: p.minutes < 15
                          ? Text(
                              'Uses alarm-based scheduling (more aggressive)',
                              style: theme.textTheme.bodySmall,
                            )
                          : null,
                      value: p.minutes,
                      enabled: widget.globalIntervalEnabled,
                    )),
              ],
            ),
          ),
          if (_effectiveMinutes < 15 && widget.globalIntervalEnabled)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: theme.colorScheme.onTertiaryContainer, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Intervals under 15 minutes use self-scheduling one-time workers. '
                      'Android Doze mode may still delay checks during deep sleep.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 13)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ),
          ],
        ),
      );

  void _save() {
    Navigator.pop(context, _buildUpdatedService());
  }
}
