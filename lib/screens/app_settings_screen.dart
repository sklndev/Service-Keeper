import 'package:flutter/material.dart';

class AppSettingsResult {
  final int? customIntervalMinutes;
  final bool appRestartEnabled;

  const AppSettingsResult({
    required this.customIntervalMinutes,
    required this.appRestartEnabled,
  });
}

class AppSettingsScreen extends StatefulWidget {
  final String appName;
  final bool globalIntervalEnabled;
  final int globalIntervalMinutes;
  final int? customIntervalMinutes;
  final bool appRestartEnabled;

  const AppSettingsScreen({
    super.key,
    required this.appName,
    required this.globalIntervalEnabled,
    required this.globalIntervalMinutes,
    required this.customIntervalMinutes,
    required this.appRestartEnabled,
  });

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  int? _customIntervalMinutes;
  late bool _appRestartEnabled;

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
    _customIntervalMinutes = widget.customIntervalMinutes;
    _appRestartEnabled = widget.appRestartEnabled;
  }

  int get _effectiveMinutes => _customIntervalMinutes ?? widget.globalIntervalMinutes;

  AppSettingsResult _buildResult() => AppSettingsResult(
        customIntervalMinutes: _customIntervalMinutes,
        appRestartEnabled: _appRestartEnabled,
      );

  bool get _hasChanges =>
      _customIntervalMinutes != widget.customIntervalMinutes ||
      _appRestartEnabled != widget.appRestartEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<AppSettingsResult>(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _hasChanges) Navigator.pop(context, _buildResult());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.appName} settings'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _buildResult()),
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
            const SizedBox(height: 16),
            Text('Restart behavior',
                style:
                    theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Restart app if a service cannot be started'),
              subtitle: Text(
                'If direct service start fails (for example JobIntentService), '
                'Service Keeper will launch the app to recover services.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              value: _appRestartEnabled,
              onChanged: (v) => setState(() => _appRestartEnabled = v),
            ),
            const SizedBox(height: 24),
            Text('Check interval',
                style:
                    theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Applies to all monitored services in this app.',
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
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                    subtitle: Text(
                      widget.globalIntervalEnabled
                          ? 'Use the value set in Settings'
                          : 'Disabled globally',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
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
}