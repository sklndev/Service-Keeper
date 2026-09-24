import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import '../app_settings_notifier.dart';
import '../models/monitored_service.dart';
import '../models/audit_event.dart';
import '../services/service_manager.dart';
import '../services/shizuku_service.dart';
import '../services/storage_service.dart';
import '../services/app_info_service.dart';
import '../services/database_service.dart';
import '../services/diagnostics_service.dart';
import '../services/system_service.dart';
import '../widgets/app_group_card.dart';
import '../widgets/app_mode_legend.dart';
import '../widgets/service_tile.dart';
import '../widgets/undo_snack_bar.dart';
import 'service_picker_screen.dart';
import 'service_detail_screen.dart';
import 'app_settings_screen.dart';
import 'service_audit_screen.dart';

Map<String, List<MonitoredService>> _groupByPackage(Iterable<MonitoredService> services) {
  final byPackage = <String, List<MonitoredService>>{};
  for (final s in services) {
    byPackage.putIfAbsent(s.packageName, () => []).add(s);
  }
  return byPackage;
}

class SelectionState {
  final int count;
  final VoidCallback onClearSelection;
  final VoidCallback onSelectAll;
  final VoidCallback onInvertSelection;
  final VoidCallback onRestartSelected;
  final VoidCallback onRemoveSelected;
  final VoidCallback onEnableSelected;
  final VoidCallback onDisableSelected;
  final VoidCallback onConfigureSelected;

  const SelectionState({
    required this.count,
    required this.onClearSelection,
    required this.onSelectAll,
    required this.onInvertSelection,
    required this.onRestartSelected,
    required this.onRemoveSelected,
    required this.onEnableSelected,
    required this.onDisableSelected,
    required this.onConfigureSelected,
  });
}

class HomeScreen extends StatefulWidget {
  final ShizukuStatus shizukuStatus;
  final Future<void> Function() onRequestShizukuPermission;
  final void Function({
    required VoidCallback refresh,
    required VoidCallback runMonitorNow,
    required VoidCallback checkStatuses,
    required VoidCallback addService,
  }) onRegister;
  final void Function(SelectionState?)? onSelectionChange;
  final void Function(String? label, VoidCallback? action)? onUndoChange;

  const HomeScreen({
    super.key,
    required this.shizukuStatus,
    required this.onRequestShizukuPermission,
    required this.onRegister,
    this.onSelectionChange,
    this.onUndoChange,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _storage = StorageService();
  final _shizuku = ShizukuService();
  final _appInfo = AppInfoService();
  final _db = DatabaseService();
  final _system = SystemService();
  late final ServiceManager _manager;

  List<MonitoredService> _services = [];
  Map<String, Uint8List?> _iconCache = {};
  Map<String, String> _appNameCache = {};
  Map<String, Color> _appColorCache = {};
  bool _useAppColors = false;
  bool _globalIntervalEnabled = true;
  int _defaultIntervalMinutes = 15;
  bool _loading = true;
  Set<String> _restoredMissingPackages = {};
  final _expandedGroups = <String, bool>{};
  final _restartingServices = <String>{};
  final _selectedServices = <String>{};
  final _checkingServices = <String>{};
  Timer? _clockTimer;
  Timer? _notificationToastTimer;
  OverlayEntry? _notificationToast;
  DateTime _now = DateTime.now();
  bool get _isInSelectionMode => _selectedServices.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    colorfulCardsNotifier.addListener(_onColorfulCardsChanged);
    _startClockTicker();
    _manager = ServiceManager(_shizuku);
    widget.onRegister(
      refresh: _reload,
      runMonitorNow: _runMonitorNow,
      checkStatuses: _refreshStatuses,
      addService: _addService,
    );
    _init();
  }

  @override
  void dispose() {
    colorfulCardsNotifier.removeListener(_onColorfulCardsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stopClockTicker();
    _notificationToastTimer?.cancel();
    _notificationToast?.remove();
    super.dispose();
  }

  void _onColorfulCardsChanged() {
    if (!mounted) return;
    setState(() => _useAppColors = colorfulCardsNotifier.value);
    if (_useAppColors) _generateAppColors();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadColorPreference();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _now = DateTime.now();
      _startClockTicker();
      _loadColorPreference();
      _loadServices();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _stopClockTicker();
    }
  }

  void _startClockTicker() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _now = DateTime.now();

      final shouldTickUi = _globalIntervalEnabled &&
          _services.any((s) => s.enabled && s.lastChecked != null);
      if (shouldTickUi) {
        setState(() {});
      }

      if (shouldTickUi) {
        _checkOverdueServices();
      }
    });
  }

  void _checkOverdueServices() {
    if (widget.shizukuStatus != ShizukuStatus.ready) return;
    if (!_globalIntervalEnabled) return;
    for (final s in _services) {
      if (!s.enabled || s.lastChecked == null) continue;
      final key = '${s.packageName}/${s.serviceClass}';
      if (_checkingServices.contains(key)) continue;
      final elapsed = _now.difference(s.lastChecked!).inSeconds;
      if (elapsed >= _effectiveInterval(s) * 60) {
        _checkingServices.add(key);
        _checkDue(s).whenComplete(() => _checkingServices.remove(key));
      }
    }
  }

  void _stopClockTicker() {
    _clockTimer?.cancel();
    _clockTimer = null;
  }

  Future<void> _init() async {
    await _db.importPendingEvents();
    await _loadSettings();
    await _loadServices();
    final missing = await _storage.loadRestoredMissingPackages();
    if (mounted) setState(() => _restoredMissingPackages = missing);
    await _system.rescheduleAllMonitorWork();
    setState(() => _loading = false);
  }

  Future<void> _reload() async {
    final oldDefault = _defaultIntervalMinutes;
    await _loadSettings();
    await _loadServices();
    final missing = await _storage.loadRestoredMissingPackages();
    if (mounted) setState(() => _restoredMissingPackages = missing);
    if (_defaultIntervalMinutes != oldDefault) {
      await _rescheduleGlobalIntervalServices();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _useAppColors = prefs.getBool('use_app_colors') ?? false;
        _globalIntervalEnabled = prefs.getBool('global_interval_enabled') ?? true;
        _defaultIntervalMinutes = prefs.getInt('default_check_interval') ?? 15;
      });
    }
  }

  Future<void> _loadColorPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _useAppColors = prefs.getBool('use_app_colors') ?? false);
  }

  int _effectiveInterval(MonitoredService service) =>
      service.customIntervalMinutes ?? _defaultIntervalMinutes;

  String _intervalLabelForNotes(int? customIntervalMinutes) {
    return customIntervalMinutes == null
        ? 'default ($_defaultIntervalMinutes min)'
        : '$customIntervalMinutes min';
  }

  Future<void> _rescheduleGlobalIntervalServices() async {
    for (final s in _services) {
      if (s.customIntervalMinutes == null) {
        final updated = s.copyWith(intervalMinutes: _defaultIntervalMinutes);
        await _storage.updateService(updated);
        if (s.enabled && _globalIntervalEnabled) await _scheduleWork(updated);
      }
    }
  }
 
  Future<void> _log(MonitoredService s, AuditEventType type, AuditTrigger trigger,
      {String? notes}) {
    return _db.addEvent(AuditEvent(
      timestamp: DateTime.now(),
      packageName: s.packageName,
      serviceClass: s.serviceClass,
      displayLabel: s.displayLabel,
      eventType: type,
      trigger: trigger,
      notes: (notes == null || notes.isEmpty) ? null : notes,
    ));
  }

  Future<void> _loadServices() async {
    final list = await _storage.loadServices();
    if (mounted) {
      setState(() {
        _services = list;
        if (_selectedServices.isNotEmpty) {
          final validKeys =
              list.map((s) => '${s.packageName}/${s.serviceClass}').toSet();
          _selectedServices.removeWhere((k) => !validKeys.contains(k));
        }
      });
      _notifySelection();
    }
    _fetchIconsAndNames(list);
    _system.startKeeperService(list.length);
    _cleanupUninstalledServices(list);
  }

  Future<void> _cleanupUninstalledServices(List<MonitoredService> services) async {
    final packages = services.map((s) => s.packageName).toSet();
    final uninstalledPkgs = <String>{};
    for (final pkg in packages) {
      final name = await _appInfo.getAppName(pkg);
      if (name == null) uninstalledPkgs.add(pkg);
    }
    if (uninstalledPkgs.isEmpty) return;
    for (final s in services.where((s) => uninstalledPkgs.contains(s.packageName))) {
      await _storage.removeService(s);
      Workmanager().cancelByTag(s.workTag);
      await _system.cancelMonitorWork(s.workTag);
    }
    final updated = await _storage.loadServices();
    if (mounted) {
      setState(() => _services = updated);
      final names = uninstalledPkgs.map((p) => p.split('.').last).join(', ');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Removed monitoring for uninstalled app(s): $names'),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _fetchIconsAndNames(List<MonitoredService> services) async {
    final prefs = await SharedPreferences.getInstance();
    final packages = services.map((s) => s.packageName).toSet();

    final cachedIcons = <String, Uint8List?>{};
    for (final pkg in packages) {
      final b64 = prefs.getString('app_icon_v1_$pkg');
      if (b64 != null) cachedIcons[pkg] = base64Decode(b64);
    }
    if (mounted && cachedIcons.isNotEmpty) {
      setState(() => _iconCache = {..._iconCache, ...cachedIcons});
    }

    final missingIcons = packages.where((p) => !cachedIcons.containsKey(p)).toSet();
    if (missingIcons.isNotEmpty) {
      final fetched = await Future.wait(
        missingIcons.map((pkg) async => MapEntry(pkg, await _appInfo.getAppIcon(pkg))),
      );
      for (final e in fetched) {
        if (e.value != null) {
          await prefs.setString('app_icon_v1_${e.key}', base64Encode(e.value!));
        }
      }
      if (mounted) setState(() => _iconCache = {..._iconCache, ...Map.fromEntries(fetched)});
    }

    final nameMap = <String, String>{};
    for (final s in services) {
      if (nameMap.containsKey(s.packageName)) continue;
      if (s.appName != null) {
        nameMap[s.packageName] = s.appName!;
      } else {
        final name = await _appInfo.getAppName(s.packageName);
        nameMap[s.packageName] = name ?? s.packageName.split('.').last;
      }
    }
    if (mounted) setState(() => _appNameCache = {..._appNameCache, ...nameMap});

    if (_useAppColors) _generateAppColors();
  }

  Future<void> _generateAppColors() async {
    final prefs = await SharedPreferences.getInstance();
    for (final pkg in _iconCache.keys) {
      if (_appColorCache.containsKey(pkg)) continue;
      final cached = prefs.getInt('app_color_v1_$pkg');
      if (cached != null && mounted) {
        setState(() => _appColorCache[pkg] = Color(cached));
      }
    }
    for (final pkg in _iconCache.keys) {
      final bytes = _iconCache[pkg];
      if (bytes == null) continue;
      try {
        final palette = await PaletteGenerator.fromImageProvider(
          MemoryImage(bytes),
          maximumColorCount: 16,
        );
        final color = palette.vibrantColor?.color ??
            palette.lightVibrantColor?.color ??
            palette.dominantColor?.color;
        if (color != null) {
          final cached = prefs.getInt('app_color_v1_$pkg');
          if (cached != color.toARGB32()) {
            await prefs.setInt('app_color_v1_$pkg', color.toARGB32());
          }
          if (mounted) setState(() => _appColorCache[pkg] = color);
        }
      } catch (_) {}
    }
  }

  Future<void> _refreshStatuses() async {
    if (widget.shizukuStatus != ShizukuStatus.ready) return;
    final updated = await Future.wait(
      _services.map((s) async {
        final running = await _manager.isServiceRunning(s);
        return s.copyWith(
          wasRunning: running ?? s.wasRunning,
          lastChecked: DateTime.now(),
        );
      }),
    );
    if (mounted) setState(() => _services = updated);
    await _storage.saveServices(updated);
  }

  Future<void> _runMonitorNow() async {
    if (widget.shizukuStatus != ShizukuStatus.ready) {
      _showShizukuWarning();
      return;
    }
    final enabledCount = _services.where((s) => s.enabled).length;
    if (enabledCount == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('No enabled services to check')));
      }
      return;
    }
    final queued = await _system.runMonitorNowForAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Triggered monitor now for $queued service${queued == 1 ? '' : 's'}')),
    );
  }

  Future<void> _scheduleWork(MonitoredService service) async {
    if (!service.enabled || !_globalIntervalEnabled) {
      Workmanager().cancelByTag(service.workTag);
      await _system.cancelMonitorWork(service.workTag);
      return;
    }

    final minutes = service.intervalMinutes;

    await _system.scheduleMonitorWork(
      packageName: service.packageName,
      serviceClass: service.serviceClass,
      displayLabel: service.displayLabel,
      intervalMinutes: minutes,
      appRestartEnabled: service.appRestartEnabled,
    );

    Workmanager().cancelByTag(service.workTag);

    if (minutes >= 15) {
      await Workmanager().registerPeriodicTask(
        service.workTag,
        'serviceCheck',
        tag: service.workTag,
        frequency: Duration(minutes: minutes),
        inputData: {
          'packageName': service.packageName,
          'serviceClass': service.serviceClass,
          'displayLabel': service.displayLabel,
        },
        constraints: Constraints(networkType: NetworkType.notRequired),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      );
    } else {
      await Workmanager().registerOneOffTask(
        '${service.workTag}_once',
        'serviceCheck',
        tag: service.workTag,
        initialDelay: Duration(minutes: minutes),
        inputData: {
          'packageName': service.packageName,
          'serviceClass': service.serviceClass,
          'displayLabel': service.displayLabel,
          'intervalMinutes': minutes,
          'selfChain': true,
        },
      );
    }

    Workmanager().cancelByTag(service.workTag);
  }

  Future<void> _onServicePicked(MonitoredService result) async {
    final existingForApp =
        _services.where((s) => s.packageName == result.packageName).toList();
    final appRestartEnabled =
        existingForApp.isNotEmpty ? existingForApp.every((s) => s.appRestartEnabled) : false;
    // New services use global interval by default (customIntervalMinutes = null)
    final service = result.copyWith(
      customIntervalMinutes: null,
      intervalMinutes: _defaultIntervalMinutes,
      appRestartEnabled: appRestartEnabled,
    );
    await _storage.addService(service);
    await _log(service, AuditEventType.added, AuditTrigger.manual);
    await _loadServices();
    await _scheduleWork(service);
  }

  Future<void> _openAppSettings(
      String pkg, String appName, List<MonitoredService> services) async {
    if (services.isEmpty) return;
    final customIntervals = services.map((s) => s.customIntervalMinutes).toSet();
    final currentCustomInterval =
        customIntervals.length == 1 ? customIntervals.first : services.first.customIntervalMinutes;
    final appRestartEnabled = services.every((s) => s.appRestartEnabled);
    final previousIntervalLabel = _intervalLabelForNotes(currentCustomInterval);

    final result = await Navigator.push<AppSettingsResult>(
      context,
      MaterialPageRoute(
        builder: (_) => AppSettingsScreen(
          appName: appName,
          globalIntervalEnabled: _globalIntervalEnabled,
          globalIntervalMinutes: _defaultIntervalMinutes,
          customIntervalMinutes: currentCustomInterval,
          appRestartEnabled: appRestartEnabled,
        ),
      ),
    );

    if (result == null) return;

    final effectiveMinutes = result.customIntervalMinutes ?? _defaultIntervalMinutes;
    var changedRestart = false;
    var changedInterval = false;

    for (final s in services) {
      final updated = s.copyWith(
        customIntervalMinutes: result.customIntervalMinutes,
        intervalMinutes: effectiveMinutes,
        appRestartEnabled: result.appRestartEnabled,
      );
      await _storage.updateService(updated);
      if (s.enabled && _globalIntervalEnabled) await _scheduleWork(updated);

      if (updated.customIntervalMinutes != s.customIntervalMinutes ||
          updated.intervalMinutes != s.intervalMinutes) {
        changedInterval = true;
      }
      if (updated.appRestartEnabled != s.appRestartEnabled) {
        changedRestart = true;
      }
    }

    if (changedInterval || changedRestart) {
      final anchor = services.first;
      if (changedInterval) {
        await _log(
          anchor,
          AuditEventType.intervalChanged,
          AuditTrigger.manual,
          notes:
              'App settings: check interval $previousIntervalLabel -> ${_intervalLabelForNotes(result.customIntervalMinutes)} for ${services.length} service(s)',
        );
      }
      if (changedRestart) {
        await _log(
          anchor,
          AuditEventType.configChanged,
          AuditTrigger.manual,
          notes:
              'App settings: restart fallback ${appRestartEnabled ? 'on' : 'off'} -> ${result.appRestartEnabled ? 'on' : 'off'} for ${services.length} service(s)',
        );
      }
    }

    await _loadServices();

    if (!mounted) return;
    final updates = <String>[];
    if (changedInterval) updates.add('check interval');
    if (changedRestart) updates.add('restart fallback');
    if (updates.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$appName: updated ${updates.join(' and ')}'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _addServiceForApp(String packageName) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServicePickerScreen(
          alreadyMonitored: _services,
          manager: _manager,
          initialQuery: packageName,
          onServiceAdded: _onServicePicked,
        ),
      ),
    );
  }

  Future<void> _addService() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServicePickerScreen(
          alreadyMonitored: _services,
          manager: _manager,
          onServiceAdded: _onServicePicked,
        ),
      ),
    );
  }

  Future<void> _configureService(MonitoredService service) async {
    final updated = await Navigator.push<MonitoredService>(
      context,
      MaterialPageRoute(
        builder: (_) => ServiceDetailScreen(
          service: service,
          globalIntervalEnabled: _globalIntervalEnabled,
          globalIntervalMinutes: _defaultIntervalMinutes,
        ),
      ),
    );
    if (updated == null) return;
    await _storage.updateService(updated);
    if (updated.customIntervalMinutes != service.customIntervalMinutes ||
        updated.intervalMinutes != service.intervalMinutes) {
      await _log(
        updated,
        AuditEventType.intervalChanged,
        AuditTrigger.manual,
        notes:
            'Service settings: check interval ${_intervalLabelForNotes(service.customIntervalMinutes)} -> ${_intervalLabelForNotes(updated.customIntervalMinutes)}',
      );
    }
    await _loadServices();
    await _scheduleWork(updated);
  }

  Future<void> _toggleService(MonitoredService service) async {
    final updated = service.copyWith(enabled: !service.enabled);
    await _storage.updateService(updated);
    await _log(updated, updated.enabled ? AuditEventType.enabled : AuditEventType.disabled,
        AuditTrigger.manual);
    await _loadServices();
    await _scheduleWork(updated);
  }

  Future<void> _removeService(MonitoredService service) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove service'),
        content: Text('Stop monitoring "${service.displayLabel}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:
                FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    Workmanager().cancelByTag(service.workTag);
    await _system.cancelMonitorWork(service.workTag);
    await _storage.removeService(service);
    await _log(service, AuditEventType.removed, AuditTrigger.manual);
    await _loadServices();
  }

  Future<void> _restartNow(MonitoredService service) async {
    if (widget.shizukuStatus != ShizukuStatus.ready) {
      _showShizukuWarning();
      return;
    }
    final key = '${service.packageName}/${service.serviceClass}';
    setState(() => _restartingServices.add(key));

    await _log(
      service,
      AuditEventType.restartAttempted,
      AuditTrigger.manual,
      notes:
          'Manual restart requested (app restart fallback: ${service.appRestartEnabled ? 'on' : 'off'})',
    );
    final (ok, detail) = await _manager.startService(service);

    bool? nowRunning;
    MonitoredService updated;
    if (ok) {
      final viaAppLaunch = detail == 'restart method: app launch';
      if (viaAppLaunch) {
        // JobIntentService runs via job scheduler — won't appear in dumpsys immediately.
        // Treat app launch success as service restart success.
        nowRunning = true;
      } else {
        await Future.delayed(const Duration(seconds: 3));
        nowRunning = await _manager.isServiceRunning(service);
      }
      updated = service.copyWith(
        lastRestarted: DateTime.now(),
        wasRunning: nowRunning ?? true,
        lastChecked: nowRunning != null ? DateTime.now() : service.lastChecked,
      );
      await _log(
          service,
          nowRunning == true ? AuditEventType.restartSuccess : AuditEventType.restartFailed,
          AuditTrigger.manual,
          notes: detail);
    } else {
      nowRunning = false;
      updated = service.copyWith(wasRunning: false);
      await _log(service, AuditEventType.restartFailed, AuditTrigger.manual, notes: detail);
    }

    await _storage.updateService(updated);
    setState(() => _restartingServices.remove(key));
    await _loadServices();

    if (mounted) {
      final success = ok && nowRunning == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success
            ? '${service.displayLabel} restarted successfully.'
            : 'Failed to restart ${service.displayLabel}.'),
        backgroundColor: success ? Colors.green : Colors.red,
      ));
    }
  }

  DateTime _retryTime(MonitoredService service,
          [Duration delay = const Duration(seconds: 30)]) =>
      DateTime.now().subtract(Duration(minutes: service.intervalMinutes)).add(delay);

  Future<void> _checkDue(MonitoredService service) async {
    if (widget.shizukuStatus != ShizukuStatus.ready) return;

    final running = await _manager.isServiceRunning(service);

    if (running == null) {
      await _storage.updateService(service.copyWith(lastChecked: _retryTime(service)));
      await _loadServices();
      return;
    }

    if (running) {
      await _storage.updateService(
          service.copyWith(wasRunning: true, lastChecked: DateTime.now()));
      await _loadServices();
      return;
    }

    await _log(
      service,
      AuditEventType.detectedStopped,
      AuditTrigger.automatic,
      notes:
          'Health check detected stopped service (interval: ${service.intervalMinutes} min)',
    );
    await _log(
      service,
      AuditEventType.restartAttempted,
      AuditTrigger.automatic,
      notes:
          'Automatic restart after failed health check (app restart fallback: ${service.appRestartEnabled ? 'on' : 'off'})',
    );
    final (ok, detail) = await _manager.startService(service);

    if (!ok) {
      await _log(service, AuditEventType.restartFailed, AuditTrigger.automatic,
          notes: detail);
      await _storage.updateService(service.copyWith(
        wasRunning: false,
        lastChecked: _retryTime(service),
      ));
      await _loadServices();
      if (mounted) {
        final hint = service.appRestartEnabled
            ? null
          : ' Try enabling app restart fallback in App settings.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Could not restart ${service.displayLabel}.${hint ?? ''}',
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 6),
        ));
      }
      return;
    }

    final viaAppLaunch = detail == 'restart method: app launch';
    bool? nowRunning;
    if (viaAppLaunch) {
      nowRunning = true; // JobIntentService won't appear in dumpsys; treat launch as success
    } else {
      await Future.delayed(const Duration(seconds: 3));
      nowRunning = await _manager.isServiceRunning(service);
    }

    if (nowRunning == true) {
      await _log(service, AuditEventType.restartSuccess, AuditTrigger.automatic,
          notes: detail);
      await _storage.updateService(service.copyWith(
        wasRunning: true,
        lastChecked: DateTime.now(),
        lastRestarted: DateTime.now(),
      ));
    } else {
      await _log(service, AuditEventType.restartFailed, AuditTrigger.automatic,
          notes: detail);
      await _storage.updateService(service.copyWith(
        wasRunning: false,
        lastChecked: _retryTime(service),
        lastRestarted: DateTime.now(),
      ));
      if (mounted) {
        final hint = service.appRestartEnabled
            ? null
          : ' Try enabling app restart fallback in App settings.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Could not restart ${service.displayLabel}.${hint ?? ''}',
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 6),
        ));
      }
    }
    await _loadServices();
  }

  Future<void> _restartAll(List<MonitoredService> services) async {
    if (widget.shizukuStatus != ShizukuStatus.ready) {
      _showShizukuWarning();
      return;
    }
    final enabled = services.where((s) => s.enabled).toList();
    if (enabled.isEmpty) return;

    setState(() {
      for (final s in enabled) {
        _restartingServices.add('${s.packageName}/${s.serviceClass}');
      }
    });

    int successCount = 0;
    int failCount = 0;

    final byPackage = _groupByPackage(enabled);

    for (final packageEntry in byPackage.entries) {
      final appFallback = <(MonitoredService, String?)>[];

      for (final s in packageEntry.value) {
        await _log(
          s,
          AuditEventType.restartAttempted,
          AuditTrigger.manual,
          notes:
              'Bulk manual direct restart (app restart fallback: ${s.appRestartEnabled ? 'on' : 'off'})',
        );
        final (ok, detail) =
            await _manager.startService(s, allowAppRestart: false);

        bool directRestarted = false;
        if (ok) {
          await Future.delayed(const Duration(seconds: 2));
          directRestarted = await _manager.isServiceRunning(s) == true;
        }

        if (directRestarted) {
          successCount++;
          await _log(s, AuditEventType.restartSuccess, AuditTrigger.manual, notes: detail);
          await _storage.updateService(s.copyWith(
            lastRestarted: DateTime.now(),
            wasRunning: true,
            lastChecked: DateTime.now(),
          ));
          setState(() => _restartingServices.remove('${s.packageName}/${s.serviceClass}'));
        } else if (s.appRestartEnabled) {
          appFallback.add((s, detail));
        } else {
          failCount++;
          await _log(
            s,
            AuditEventType.restartFailed,
            AuditTrigger.manual,
            notes: detail ?? 'Direct restart did not leave the service running',
          );
          await _storage.updateService(s.copyWith(wasRunning: false));
          setState(() => _restartingServices.remove('${s.packageName}/${s.serviceClass}'));
        }
      }

      if (appFallback.isEmpty) continue;

      final appStarted = await _manager.restartApp(packageEntry.key);
      for (final (service, directDetail) in appFallback) {
        if (appStarted) {
          successCount++;
          await _log(
            service,
            AuditEventType.restartSuccess,
            AuditTrigger.manual,
            notes: 'restart method: app launch (grouped)',
          );
          await _storage.updateService(service.copyWith(
            lastRestarted: DateTime.now(),
            wasRunning: true,
            lastChecked: DateTime.now(),
          ));
        } else {
          failCount++;
          final notes = directDetail == null || directDetail.isEmpty
              ? 'Direct restart failed; grouped app restart failed'
              : '$directDetail; grouped app restart failed';
          await _log(
            service,
            AuditEventType.restartFailed,
            AuditTrigger.manual,
            notes: notes,
          );
          await _storage.updateService(service.copyWith(wasRunning: false));
        }
        setState(() => _restartingServices
            .remove('${service.packageName}/${service.serviceClass}'));
      }
    }

    await _loadServices();
    if (mounted) {
      final String msg;
      final Color? color;
      if (failCount == 0) {
        msg = 'All $successCount service${successCount == 1 ? '' : 's'} restarted successfully.';
        color = Colors.green;
      } else if (successCount == 0) {
        msg = 'Failed to restart $failCount service${failCount == 1 ? '' : 's'}.';
        color = Colors.red;
      } else {
        msg = '$successCount restarted, $failCount failed.';
        color = Colors.orange;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: color),
      );
    }
  }

  String _serviceKey(MonitoredService s) => '${s.packageName}/${s.serviceClass}';
  bool _isServiceSelected(MonitoredService s) => _selectedServices.contains(_serviceKey(s));
  bool _isAppSelected(List<MonitoredService> services) =>
      services.isNotEmpty && services.every(_isServiceSelected);
  bool _isAppPartiallySelected(List<MonitoredService> services) =>
      !_isAppSelected(services) && services.any(_isServiceSelected);
  List<MonitoredService> get _selectedServiceList =>
      _services.where((s) => _selectedServices.contains(_serviceKey(s))).toList();

  void _toggleServiceSelection(MonitoredService s) {
    final key = _serviceKey(s);
    setState(() {
      if (_selectedServices.contains(key)) {
        _selectedServices.remove(key);
      } else {
        _selectedServices.add(key);
      }
    });
    _notifySelection();
  }

  void _toggleAppSelection(List<MonitoredService> services) {
    final allSelected = _isAppSelected(services);
    setState(() {
      for (final s in services) {
        final key = _serviceKey(s);
        if (allSelected) {
          _selectedServices.remove(key);
        } else {
          _selectedServices.add(key);
        }
      }
    });
    _notifySelection();
  }

  void _clearSelection() {
    setState(() => _selectedServices.clear());
    _notifySelection();
  }

  void _selectAll() {
    setState(() {
      for (final s in _services) {
        _selectedServices.add(_serviceKey(s));
      }
    });
    _notifySelection();
  }

  void _invertSelection() {
    setState(() {
      final allKeys = _services.map(_serviceKey).toSet();
      final inverted = allKeys.difference(_selectedServices);
      _selectedServices
        ..clear()
        ..addAll(inverted);
    });
    _notifySelection();
  }

  void _notifySelection() {
    if (_selectedServices.isEmpty) {
      widget.onSelectionChange?.call(null);
      return;
    }
    widget.onSelectionChange?.call(SelectionState(
      count: _selectedServices.length,
      onClearSelection: _clearSelection,
      onSelectAll: _selectAll,
      onInvertSelection: _invertSelection,
      onRestartSelected: _restartSelected,
      onRemoveSelected: _removeSelected,
      onEnableSelected: _enableSelected,
      onDisableSelected: _disableSelected,
      onConfigureSelected: _configureSelected,
    ));
  }

  Future<void> _removeApp(
      String pkg, String appName, List<MonitoredService> services) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove app'),
        content: Text('Stop monitoring all services for "$appName"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final s in services) {
      Workmanager().cancelByTag(s.workTag);
      await _system.cancelMonitorWork(s.workTag);
      await _storage.removeService(s);
      await _log(s, AuditEventType.removed, AuditTrigger.manual);
    }
    if (_restoredMissingPackages.contains(pkg)) {
      await _storage.clearRestoredMissingPackage(pkg);
      _restoredMissingPackages.remove(pkg);
    }
    await _loadServices();
  }

  Future<void> _removeSelected() async {
    final selected = _selectedServiceList;
    if (selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove services'),
        content: Text(
            'Remove monitoring for ${selected.length} service${selected.length == 1 ? '' : 's'}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final s in selected) {
      Workmanager().cancelByTag(s.workTag);
      await _system.cancelMonitorWork(s.workTag);
      await _storage.removeService(s);
      await _log(s, AuditEventType.removed, AuditTrigger.manual);
    }
    _clearSelection();
    await _loadServices();
  }

  Future<void> _enableSelected() async {
    for (final s in _selectedServiceList) {
      final updated = s.copyWith(enabled: true);
      await _storage.updateService(updated);
      await _log(updated, AuditEventType.enabled, AuditTrigger.manual);
      await _scheduleWork(updated);
    }
    _clearSelection();
    await _loadServices();
  }

  Future<void> _disableSelected() async {
    for (final s in _selectedServiceList) {
      final updated = s.copyWith(enabled: false);
      await _storage.updateService(updated);
      await _log(updated, AuditEventType.disabled, AuditTrigger.manual);
      await _scheduleWork(updated);
    }
    _clearSelection();
    await _loadServices();
  }

  Future<void> _restartSelected() async {
    final selected = _selectedServiceList;
    if (selected.isEmpty) return;
    await _restartAll(selected);
    _clearSelection();
  }

  Future<void> _configureSelected() async {
    final selected = _selectedServiceList;
    if (selected.isEmpty) return;
    final updated = await Navigator.push<MonitoredService>(
      context,
      MaterialPageRoute(
        builder: (_) => ServiceDetailScreen(
          service: selected.first,
          globalIntervalEnabled: _globalIntervalEnabled,
          globalIntervalMinutes: _defaultIntervalMinutes,
        ),
      ),
    );
    if (updated == null) return;
    for (final s in selected) {
      final updatedS = s.copyWith(
        customIntervalMinutes: updated.customIntervalMinutes,
        intervalMinutes: updated.intervalMinutes,
      );
      await _storage.updateService(updatedS);
      await _scheduleWork(updatedS);
      if (updatedS.customIntervalMinutes != s.customIntervalMinutes ||
          updatedS.intervalMinutes != s.intervalMinutes) {
        final mins = updatedS.customIntervalMinutes ?? _defaultIntervalMinutes;
        await _log(updatedS, AuditEventType.intervalChanged, AuditTrigger.manual,
            notes: 'Every ${mins}m (bulk configure)');
      }
    }
    _clearSelection();
    await _loadServices();
  }


  Future<void> _reportServiceIssue(
      MonitoredService service, String appName) async {
    if (!mounted) return;
    final diag = DiagnosticsService(_shizuku, _db);
    var loadingOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Gathering diagnostics…'),
        ]),
      ),
    );
    try {
      final body = await diag.buildServiceReport(service, appName);
      if (!mounted) return;
      if (loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingOpen = false;
      }
      final title =
          'Service not kept alive: ${service.displayLabel} (${service.packageName})';
      await DiagnosticsService.openGitHubIssue(context,
          title: title, body: body);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to generate diagnostics: $e')),
        );
      }
    } finally {
      if (mounted && loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<void> _reportAppIssue(
      String pkg, String appName, List<MonitoredService> services) async {
    if (!mounted) return;
    final diag = DiagnosticsService(_shizuku, _db);
    var loadingOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Gathering diagnostics…'),
        ]),
      ),
    );
    try {
      final body = await diag.buildAppReport(pkg, appName, services);
      if (!mounted) return;
      if (loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingOpen = false;
      }
      final title = 'Services not kept alive: $appName ($pkg)';
      await DiagnosticsService.openGitHubIssue(context,
          title: title, body: body);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to generate diagnostics: $e')),
        );
      }
    } finally {
      if (mounted && loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  void _viewAppHistory(String packageName, String appName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ServiceAuditScreen.forApp(packageName: packageName, appName: appName),
      ),
    );
  }

  Future<void> _toggleServiceNotification(MonitoredService service) async {
    final nowEnabled = !service.notificationsEnabled;
    final updated = service.copyWith(notificationsEnabled: nowEnabled);
    setState(() {
      _services = _services.map((s) => s == service ? updated : s).toList();
    });
    await _storage.updateService(updated);
    await _log(
      updated,
      nowEnabled
          ? AuditEventType.notificationsEnabled
          : AuditEventType.notificationsDisabled,
      AuditTrigger.manual,
    );
    if (mounted) {
      _showNotificationToast(
        nowEnabled
            ? 'Notifications enabled for ${service.serviceDisplayName}'
            : 'Notifications disabled for ${service.serviceDisplayName}',
        enabled: nowEnabled,
      );
    }
  }

  void _showNotificationToast(String message, {required bool enabled}) {
    _notificationToastTimer?.cancel();
    _notificationToast?.remove();

    final entry = OverlayEntry(
      builder: (overlayContext) {
        final theme = Theme.of(overlayContext);
        return Positioned.fill(
          child: IgnorePointer(
            child: SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 180),
                  tween: Tween(begin: 0, end: 1),
                  builder: (_, value, child) => Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 8 * (1 - value)),
                      child: child,
                    ),
                  ),
                  child: Material(
                    key: const ValueKey('notification-toast-pill'),
                    color: theme.colorScheme.inverseSurface,
                    elevation: 6,
                    shadowColor: Colors.black38,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            enabled
                                ? Icons.notifications_active
                                : Icons.notifications_off,
                            size: 17,
                            color: theme.colorScheme.onInverseSurface,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onInverseSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    _notificationToast = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    _notificationToastTimer = Timer(const Duration(seconds: 2), () {
      if (_notificationToast == entry) {
        entry.remove();
        _notificationToast = null;
      }
    });
  }

  Future<void> _setGroupState(
      String pkg, List<MonitoredService> services, int state) async {
    final previous = List<MonitoredService>.from(services);
    final nowEnabled = state != 0;
    final nowNotif = state == 2;
    for (final s in services) {
      final updated = s.copyWith(enabled: nowEnabled, notificationsEnabled: nowNotif);
      await _storage.updateService(updated);
      if (s.enabled != nowEnabled) {
        await _log(updated,
            nowEnabled ? AuditEventType.enabled : AuditEventType.disabled,
            AuditTrigger.manual);
      }
      if (s.notificationsEnabled != nowNotif) {
        await _log(
          updated,
          nowNotif
              ? AuditEventType.notificationsEnabled
              : AuditEventType.notificationsDisabled,
          AuditTrigger.manual,
          notes: 'App group state changed',
        );
      }
      await _scheduleWork(updated);
    }
    await _loadServices();
    if (!mounted) return;
    final appName = _appNameCache[pkg] ?? pkg.split('.').last;
    final label = state == 0 ? 'Disabled' : state == 1 ? 'Monitor' : 'Notify';
    final message = '$appName: $label';

    Future<void> undoFn() async {
      for (final s in previous) {
        await _storage.updateService(s);
        await _scheduleWork(s);
      }
      await _loadServices();
      widget.onUndoChange?.call(null, null);
    }

    widget.onUndoChange?.call(message, undoFn);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(buildUndoSnackBar(message: message, onUndo: undoFn));
  }

  void _showShizukuWarning() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Shizuku Required'),
        content: const Text(
          'Shizuku is not active. Please:\n\n'
          '1. Install Shizuku from Play Store\n'
          '2. Enable it via Wireless Debugging\n'
          '   (Developer Options → Wireless debugging)\n'
          '3. Return to this app',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.onRequestShizukuPermission();
            },
            child: const Text('Grant Permission'),
          ),
        ],
      ),
    );
  }

  List<(String pkg, String appName, List<MonitoredService> services)> _groupedServices() {
    final groups = _groupByPackage(_services);
    final result = groups.entries.map((e) {
      final name = _appNameCache[e.key] ?? e.key.split('.').last;
      final sorted = [...e.value]
        ..sort((a, b) =>
            a.serviceDisplayName.toLowerCase().compareTo(b.serviceDisplayName.toLowerCase()));
      return (e.key, name, sorted);
    }).toList();
    result.sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_services.isEmpty) return _buildEmptyState();
    return RefreshIndicator(
        onRefresh: _refreshStatuses,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            for (final (pkg, appName, services) in _groupedServices())
              _buildAppGroupCard(context, pkg, appName, services),
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
    );
  }

  Widget _buildAppGroupCard(
    BuildContext context,
    String pkg,
    String appName,
    List<MonitoredService> services,
  ) {
    final appColor = _useAppColors ? _appColorCache[pkg] : null;
    final isMissingAfterRestore = _restoredMissingPackages.contains(pkg);
    final anyIssue = services.any((s) => s.state == ServiceState.crashed);
    final anyEnabled = services.any((s) => s.enabled);
    final enabledSvcs = services.where((s) => s.enabled);
    final allEnabledNotifOff = anyEnabled &&
        enabledSvcs.every((s) => !s.notificationsEnabled);
    final groupState = !anyEnabled ? 0 : allEnabledNotifOff ? 1 : 2;
    final appRestartEnabled = services.every((s) => s.appRestartEnabled);

    final Color? headerFg = appColor == null
        ? null
        : (ThemeData.estimateBrightnessForColor(appColor) == Brightness.dark
            ? Colors.white
            : Colors.black87);

    final menuItems = <PopupMenuEntry<String>>[
      const PopupMenuItem(
        value: 'app_settings',
        child: Row(children: [
          Icon(Icons.tune_outlined, size: 16),
          SizedBox(width: 8),
          Text('App settings'),
        ]),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'add_services',
        child: Row(children: [
          Icon(Icons.add, size: 16),
          SizedBox(width: 8),
          Text('Add services'),
        ]),
      ),
      const PopupMenuItem(
        value: 'restart_all',
        child: Row(children: [
          Icon(Icons.restart_alt_outlined, size: 16),
          SizedBox(width: 8),
          Text('Restart all'),
        ]),
      ),
      const PopupMenuItem(
        value: 'view_history',
        child: Row(children: [
          Icon(Icons.history_outlined, size: 16),
          SizedBox(width: 8),
          Text('View history'),
        ]),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'report_issue',
        child: Row(children: [
          Icon(Icons.bug_report_outlined, size: 16),
          SizedBox(width: 8),
          Text('Report Issue'),
        ]),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'remove_app',
        child: Row(children: [
          Icon(Icons.delete_outline, size: 16, color: Colors.red),
          SizedBox(width: 8),
          Text('Remove app', style: TextStyle(color: Colors.red)),
        ]),
      ),
    ];

    return AppGroupCard(
      key: ValueKey(pkg),
      expanded: _expandedGroups[pkg] ?? false,
      onToggleExpanded: () =>
          setState(() => _expandedGroups[pkg] = !(_expandedGroups[pkg] ?? false)),
      packageName: pkg,
      appName: appName,
      serviceCount: services.length,
      icon: _AppIconWithRings(
        iconBytes: _iconCache[pkg],
        packageName: pkg,
        appColor: appColor,
        headerFg: headerFg,
        services: services,
        globalIntervalMinutes: _defaultIntervalMinutes,
        globalIntervalEnabled: _globalIntervalEnabled,
        now: _now,
      ),
      appColor: appColor,
        subtitle: 'App restart ${appRestartEnabled ? 'on' : 'off'}',
      groupState: groupState,
      hasIssue: anyIssue,
      onGroupStateChanged: (state) => _setGroupState(pkg, services, state),
      menuItems: menuItems,
      onMenuSelected: (v) {
        if (v == 'app_settings') _openAppSettings(pkg, appName, services);
        if (v == 'add_services') _addServiceForApp(pkg);
        if (v == 'restart_all') _restartAll(services);
        if (v == 'view_history') _viewAppHistory(pkg, appName);
        if (v == 'report_issue') _reportAppIssue(pkg, appName, services);
        if (v == 'remove_app') _removeApp(pkg, appName, services);
      },
      onSelect: () => _toggleAppSelection(services),
      isInSelectionMode: _isInSelectionMode,
      isSelected: _isAppSelected(services),
      isPartiallySelected: _isAppPartiallySelected(services),
      isRestoredMissing: isMissingAfterRestore,
      children: [
        AppModeLegend(
          value: groupState,
          onChanged: (state) => _setGroupState(pkg, services, state),
        ),
        for (final s in services) _buildServiceRow(context, pkg, s, appColor),
      ],
    );
  }

  Widget _buildServiceRow(
    BuildContext context,
    String pkg,
    MonitoredService s,
    Color? appColor,
  ) {
    final theme = Theme.of(context);
    return GestureDetector(
      onLongPress: _isInSelectionMode ? null : () => _toggleServiceSelection(s),
      onTap: _isInSelectionMode ? () => _toggleServiceSelection(s) : null,
      child: Stack(
        children: [
          if (_isServiceSelected(s))
            Positioned.fill(
              child: ColoredBox(
                color: appColor != null
                    ? appColor.withValues(alpha: 0.25)
                    : theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              ),
            ),
          Row(
            children: [
              if (_isInSelectionMode)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Icon(
                    _isServiceSelected(s)
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 20,
                    color: _isServiceSelected(s)
                        ? (appColor ?? theme.colorScheme.primary)
                        : theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.5),
                  ),
                ),
              Expanded(
                child: ServiceTile(
                  service: s,
                  now: _now,
                  showLeading: false,
                  accentColor: appColor,
                  globalIntervalEnabled: _globalIntervalEnabled,
                  effectiveIntervalMinutes: _effectiveInterval(s),
                  isRestarting: _restartingServices
                      .contains('${s.packageName}/${s.serviceClass}'),
                  onToggle:
                      _isInSelectionMode ? null : () => _toggleService(s),
                  onConfigure:
                      _isInSelectionMode ? null : () => _configureService(s),
                  onRemove:
                      _isInSelectionMode ? null : () => _removeService(s),
                  onRestartNow:
                      _isInSelectionMode ? null : () => _restartNow(s),
                  onCheckDue: null,
                  onToggleNotifications: _isInSelectionMode
                      ? null
                      : () => _toggleServiceNotification(s),
                  onViewHistory: _isInSelectionMode
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ServiceAuditScreen(service: s),
                            ),
                          ),
                  onReportIssue: _isInSelectionMode
                      ? null
                      : () => _reportServiceIssue(
                            s,
                            _appNameCache[pkg] ?? pkg.split('.').last,
                          ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings_suggest,
                size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('No services monitored', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Tap "Add Service" to browse running Android services '
              'and select which ones to keep alive.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppIconWithRings extends StatefulWidget {
  final Uint8List? iconBytes;
  final String packageName;
  final Color? appColor;
  final Color? headerFg;
  final List<MonitoredService> services;
  final int globalIntervalMinutes;
  final bool globalIntervalEnabled;
  final DateTime now;

  const _AppIconWithRings({
    required this.packageName,
    this.iconBytes,
    this.appColor,
    this.headerFg,
    required this.services,
    required this.globalIntervalMinutes,
    required this.globalIntervalEnabled,
    required this.now,
  });

  @override
  State<_AppIconWithRings> createState() => _AppIconWithRingsState();
}

class _AppIconWithRingsState extends State<_AppIconWithRings> {

  int _effectiveInterval(MonitoredService s) =>
      s.customIntervalMinutes ?? widget.globalIntervalMinutes;

  double _progressForInterval(int intervalMinutes) {
    final relevant = widget.services.where(
        (s) => s.enabled && s.lastChecked != null && _effectiveInterval(s) == intervalMinutes);
    if (relevant.isEmpty) return 1.0;
    double minProgress = 1.0;
    for (final s in relevant) {
      final elapsed = widget.now.difference(s.lastChecked!).inSeconds;
      final total = intervalMinutes * 60;
      final p = total <= 0 ? 0.0 : ((total - elapsed) / total).clamp(0.0, 1.0);
      if (p < minProgress) minProgress = p;
    }
    return minProgress;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isColorful = widget.appColor != null;

    final Widget avatar = widget.iconBytes != null
        ? CircleAvatar(
            radius: 20,
            backgroundImage: MemoryImage(widget.iconBytes!),
            backgroundColor: Colors.transparent,
          )
        : CircleAvatar(
            radius: 20,
            backgroundColor: widget.appColor ?? theme.colorScheme.primaryContainer,
            child: Text(
              widget.packageName.isNotEmpty
                  ? widget.packageName.split('.').last[0].toUpperCase()
                  : '?',
              style: TextStyle(
                  color: widget.headerFg ?? theme.colorScheme.onPrimaryContainer),
            ),
          );

    if (!widget.globalIntervalEnabled) return avatar;

    final hasEnabled = widget.services.any((s) => s.enabled);
    final tracked = widget.services
        .where((s) => s.enabled && s.lastChecked != null)
        .toList();
    final uniqueIntervals =
        tracked.map(_effectiveInterval).toSet().toList()..sort();

    if (uniqueIntervals.isEmpty) {
      if (!hasEnabled) return avatar;
      return SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 43,
              height: 43,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                strokeCap: StrokeCap.round,
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.colorScheme.tertiary.withValues(alpha: 0.75),
                ),
              ),
            ),
            avatar,
          ],
        ),
      );
    }

    final opacity = 1.0 / uniqueIntervals.length;

    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ...uniqueIntervals.map((interval) {
            final progress = _progressForInterval(interval);
            final Color ringColor;
            if (isColorful) {
              ringColor =
                  (widget.headerFg ?? Colors.white).withValues(alpha: opacity);
            } else {
              final base =
                  progress < 0.15 ? Colors.orange : theme.colorScheme.primary;
              ringColor = base.withValues(alpha: opacity.clamp(0.4, 1.0));
            }
            return SizedBox(
              width: 43,
              height: 43,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 3.5,
                strokeCap: StrokeCap.round,
                backgroundColor: ringColor.withValues(alpha: 0.18),
                valueColor: AlwaysStoppedAnimation<Color>(ringColor),
              ),
            );
          }),
          avatar,
        ],
      ),
    );
  }
}
