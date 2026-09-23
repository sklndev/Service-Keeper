import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_settings_notifier.dart';
import '../services/storage_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = StorageService();

  bool _useAppColors = false;
  bool _globalIntervalEnabled = true;
  int _defaultInterval = 15;
  String _relaunchIdleMode = 'inactivity';
  int _relaunchInactivitySeconds = 60;

  static const _intervalPresets = [
    (label: '5 minutes', minutes: 5),
    (label: '10 minutes', minutes: 10),
    (label: '15 minutes', minutes: 15),
    (label: '30 minutes', minutes: 30),
    (label: '1 hour', minutes: 60),
    (label: '2 hours', minutes: 120),
    (label: '4 hours', minutes: 240),
  ];

  static const _inactivitySecondsPresets = [
    (label: '15 seconds', seconds: 15),
    (label: '30 seconds', seconds: 30),
    (label: '1 minute', seconds: 60),
    (label: '2 minutes', seconds: 120),
    (label: '5 minutes', seconds: 300),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final relaunchIdleMode = await _storage.getRelaunchIdleMode();
    final relaunchInactivitySeconds = await _storage.getRelaunchInactivitySeconds();
    if (!mounted) return;
    setState(() {
      _useAppColors = prefs.getBool('use_app_colors') ?? false;
      _globalIntervalEnabled = prefs.getBool('global_interval_enabled') ?? true;
      _defaultInterval = prefs.getInt('default_check_interval') ?? 15;
      _relaunchIdleMode = relaunchIdleMode;
      _relaunchInactivitySeconds = relaunchInactivitySeconds;
    });
  }

  Future<void> _setAppColors(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_app_colors', value);
    colorfulCardsNotifier.value = value;
    setState(() => _useAppColors = value);
  }

  Future<void> _setGlobalIntervalEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('global_interval_enabled', value);
    setState(() => _globalIntervalEnabled = value);
  }

  Future<void> _resetBanners() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset banners?'),
        content: const Text(
          'All dismissed tips and info banners will be shown again throughout the app, '
          'as if it was just installed.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      'app_restart_tip_dismissed',
      'monitoring_explainer_dismissed',
      'toggle_explainer_dismissed',
      'a11y_perm_info_dismissed',
      'a11y_revoke_banner_dismissed',
      'notif_perm_info_dismissed',
      'notif_revoke_banner_dismissed',
    ]) {
      await prefs.remove(key);
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _setDefaultInterval(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('default_check_interval', minutes);
    setState(() => _defaultInterval = minutes);
  }

  Future<void> _setRelaunchIdleMode(String mode) async {
    await _storage.setRelaunchIdleMode(mode);
    setState(() => _relaunchIdleMode = mode);
  }

  Future<void> _setRelaunchInactivitySeconds(int seconds) async {
    await _storage.setRelaunchInactivitySeconds(seconds);
    setState(() => _relaunchInactivitySeconds = seconds);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _sectionHeader(context, 'Appearance'),
          SwitchListTile(
            title: const Text('Colorful app cards'),
            subtitle: const Text(
              'Tints each app card and its toggle switch with colors extracted from the app\'s icon.',
            ),
            value: _useAppColors,
            onChanged: _setAppColors,
          ),
          const Divider(height: 1),
          _sectionHeader(context, 'Interval checking'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(Icons.info_outline,
                        color: theme.colorScheme.onSurfaceVariant, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Service Keeper watches Android\'s activity log in real time. '
                      'The moment a monitored service stops — crash, force-stop, or system kill — '
                      'it restarts straight away without needing a scheduled check.\n\n'
                      'Interval checking is a safety net that periodically re-checks all services '
                      'to catch anything the live watcher may have missed '
                      '(e.g. if Shizuku was briefly offline). It\'s optional.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Enable interval checking'),
            subtitle: Text(
              _globalIntervalEnabled
                  ? 'Services are checked on their configured schedule.'
                  : 'Automatic scheduled checks are off. Services are only restarted when Service Keeper observes a change via logcat.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            value: _globalIntervalEnabled,
            onChanged: _setGlobalIntervalEnabled,
          ),
          if (_globalIntervalEnabled) ...[
            if (_defaultInterval < 15)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.battery_alert,
                          color: theme.colorScheme.onErrorContainer, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Intervals under 15 minutes use self-scheduling workers and drain battery faster.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            _sectionHeader(context, 'Default check interval'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Applied to new services. Services with a custom interval are not affected.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            RadioGroup<int>(
              groupValue: _defaultInterval,
              onChanged: (value) {
                if (value != null) _setDefaultInterval(value);
              },
              child: Column(
                children: _intervalPresets.map((p) => RadioListTile<int>(
                      title: Text(p.label),
                      subtitle: p.minutes < 15
                          ? Text(
                              'Alarm-based scheduling — more aggressive, higher battery use',
                              style: theme.textTheme.bodySmall,
                            )
                          : null,
                      value: p.minutes,
                    )).toList(),
              ),
            ),
            if (_defaultInterval < 15)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
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
              ),
          ] else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Container(
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
                        'Default interval setting is disabled while interval checking is off.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const Divider(height: 1),
          _sectionHeader(context, 'App relaunch'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(Icons.info_outline,
                        color: theme.colorScheme.onSurfaceVariant, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'When a service can only be recovered by fully relaunching '
                      'its app, Service Keeper briefly switches to it and back. '
                      'Choose when that\'s allowed to happen.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
          RadioGroup<String>(
            groupValue: _relaunchIdleMode,
            onChanged: (value) {
              if (value != null) _setRelaunchIdleMode(value);
            },
            child: Column(
              children: [
                const RadioListTile<String>(
                  title: Text('Always'),
                  subtitle: Text('Relaunch immediately, even while you\'re using the phone.'),
                  value: 'always',
                ),
                const RadioListTile<String>(
                  title: Text('No app open'),
                  subtitle: Text('Only when the home screen is showing, no app in front.'),
                  value: 'no_foreground_app',
                ),
                const RadioListTile<String>(
                  title: Text('No activity for a while'),
                  subtitle: Text('Only after you\'ve stopped tapping or scrolling.'),
                  value: 'inactivity',
                ),
                if (_relaunchIdleMode == 'inactivity')
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      children: _inactivitySecondsPresets
                          .map((p) => ChoiceChip(
                                label: Text(p.label),
                                selected: _relaunchInactivitySeconds == p.seconds,
                                onSelected: (_) => _setRelaunchInactivitySeconds(p.seconds),
                              ))
                          .toList(),
                    ),
                  ),
                const RadioListTile<String>(
                  title: Text('When locked'),
                  subtitle: Text('Only right after you unlock the phone.'),
                  value: 'locked',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _sectionHeader(context, 'Banners'),
          ListTile(
            leading: Icon(Icons.info_outline,
                color: theme.colorScheme.onSurfaceVariant),
            title: const Text('Reset dismissed banners'),
            subtitle: const Text(
              'Shows all tips and info banners again throughout the app, '
              'as if it was just installed.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _resetBanners,
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
        ),
      );
}
