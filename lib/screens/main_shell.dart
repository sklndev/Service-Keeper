import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:service_keeper/widgets/page_banner.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_settings_notifier.dart';
import '../models/audit_event.dart';
import '../services/app_info_service.dart';
import '../services/backup_service.dart';
import '../services/database_service.dart';
import '../services/shizuku_service.dart';
import '../services/storage_service.dart';
import '../services/system_service.dart';
import 'about_screen.dart';
import 'accessibility_monitor_screen.dart';
import 'home_screen.dart';
import 'notification_monitor_screen.dart';
import 'settings_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _currentIndex = 0;
  late final PageController _pageController = PageController();

  final _shizuku = ShizukuService();
  final _system = SystemService();
  final _storage = StorageService();
  final _db = DatabaseService();

  ShizukuStatus _shizukuStatus = ShizukuStatus.notInstalled;
  DateTime? _shizukuReadySince;
  Timer? _durationTimer;
  bool _batteryExempt = true;
  bool _notificationPermissionGranted = true;
  bool? _appRestartTipDismissed;
  bool? _monitoringExplainerDismissed;
  bool? _toggleExplainerDismissed;

  final _refreshCallbacks = <int, VoidCallback>{};
  VoidCallback? _runMonitorNow;
  VoidCallback? _checkStatuses;
  VoidCallback? _addService;
  SelectionState? _selectionState;
  String? _undoLabel;
  VoidCallback? _undoAction;
  Timer? _undoTimer;

  void _registerUndo(String? label, VoidCallback? action) {
    _undoTimer?.cancel();
    _undoTimer = null;
    setState(() {
      _undoLabel = label;
      _undoAction = action;
    });
    if (action != null) {
      _undoTimer = Timer(const Duration(seconds: 10), () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        setState(() {
          _undoLabel = null;
          _undoAction = null;
        });
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _undoTimer?.cancel();
    _pageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkShizuku();
      _checkBatteryOptimization();
      _checkNotificationPermission();
    }
  }

  Future<void> _init() async {
    await _reloadBannerStates();
    await _checkShizuku();
    await _checkBatteryOptimization();
    await _checkNotificationPermission();
    await _loadIntervalSetting();
  }

  Future<void> _loadIntervalSetting() async {
    // HomeScreen reads this itself; called here only to trigger HomeScreen refresh after settings change
  }

  Future<void> _reloadBannerStates() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() {
      _appRestartTipDismissed = prefs.getBool('app_restart_tip_dismissed') ?? false;
      _monitoringExplainerDismissed = prefs.getBool('monitoring_explainer_dismissed') ?? false;
      _toggleExplainerDismissed = prefs.getBool('toggle_explainer_dismissed') ?? false;
    });
  }

  Future<void> _checkShizuku() async {
    final status = await _shizuku.checkStatus();
    if (!mounted) return;
    final wasReady = _shizukuStatus == ShizukuStatus.ready;
    final prefs = await SharedPreferences.getInstance();
    if (status == ShizukuStatus.ready) {
      if (_shizukuReadySince == null) {
        final stored = prefs.getInt('shizuku_ready_since');
        final since = stored != null
            ? DateTime.fromMillisecondsSinceEpoch(stored)
            : DateTime.now();
        if (stored == null) {
          await prefs.setInt('shizuku_ready_since', since.millisecondsSinceEpoch);
        }
        setState(() {
          _shizukuStatus = status;
          _shizukuReadySince = since;
        });
        // Timer calls _checkShizuku so it detects when Shizuku goes offline
        _durationTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
          if (mounted) _checkShizuku();
        });
      } else {
        setState(() => _shizukuStatus = status);
      }
    } else {
      await prefs.remove('shizuku_ready_since');
      _durationTimer?.cancel();
      _durationTimer = null;
      setState(() {
        _shizukuStatus = status;
        _shizukuReadySince = null;
      });
      // Notify user if Shizuku just went offline
      if (wasReady) {
        await _system.postShizukuOfflineNotification();
      }
    }
  }

  Future<void> _checkBatteryOptimization() async {
    final exempt = await _system.isBatteryOptimizationExempt();
    if (mounted) setState(() => _batteryExempt = exempt);
  }

  Future<void> _checkNotificationPermission() async {
    final granted = await _system.isNotificationPermissionGranted();
    if (mounted) setState(() => _notificationPermissionGranted = granted);
  }

  Future<void> _requestShizukuPermission() async {
    await _shizuku.requestPermission();
    await _checkShizuku();
  }

  Widget _buildShizukuBanner() {
    if (_shizukuStatus == ShizukuStatus.ready) return const SizedBox.shrink();
    final label = switch (_shizukuStatus) {
      ShizukuStatus.permissionDenied => 'Shizuku: permission denied',
      ShizukuStatus.notRunning => 'Shizuku not running',
      ShizukuStatus.notInstalled => 'Shizuku not installed',
      ShizukuStatus.ready => '',
    };
    return GestureDetector(
      onTap: _showShizukuWarning,
      child: Container(
        color: Colors.orange.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(
                  color: Colors.orange, fontWeight: FontWeight.w600, fontSize: 13)),
          const Spacer(),
          const Text('Tap to fix →', style: TextStyle(color: Colors.orange, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildBatteryBanner() {
    if (_batteryExempt) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () async => _system.requestBatteryOptimizationExemption(),
      child: Container(
        color: Colors.deepOrange.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: const Row(children: [
          Icon(Icons.battery_alert, color: Colors.deepOrange, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Battery optimization active — checks may be delayed',
              style: TextStyle(
                  color: Colors.deepOrange, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          Text('Tap to fix →', style: TextStyle(color: Colors.deepOrange, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildMonitoringExplainerBanner() {
    if (_monitoringExplainerDismissed != false) return const SizedBox.shrink();
    return PageBanner(
      pref: 'monitoring_explainer_dismissed',
      dismissed: false,
      text:
            'Service Keeper runs a persistent background watcher that reads Android\'s activity log in real time. '
          'The moment a monitored service stops Service Keeper detects it and restarts it straight away. '
            'Interval checking is a safety net: it periodically re-checks all services to catch '
            'anything the live watcher may have missed (e.g. if Shizuku was briefly offline). '
            'It\'s optional, but useful as a backup.',
      onDismiss: () {
            if (mounted) setState(() => _monitoringExplainerDismissed = true);
          },
      icon: Icons.info,
      color:
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
      textColor: Theme.of(context).colorScheme.onPrimaryContainer,
      iconColor: Theme.of(context).colorScheme.onPrimaryContainer,
      pageIndex: 0,
      pageController: _pageController,
    );
  }

  Widget _buildAppRestartTipBanner() {
    if (_appRestartTipDismissed != false) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return PageBanner(
      pref: 'app_restart_tip_dismissed',
      dismissed: false,
      text: 'Tip: If a service can\'t be started directly, enable app restart fallback in App settings to launch the app instead.',

      onDismiss: () {
            if (mounted) setState(() => _appRestartTipDismissed = true);
          },
      icon: Icons.open_in_browser_outlined,
      color:
          cs.tertiaryContainer.withValues(alpha: 0.45),
      textColor: cs.onTertiaryContainer,
      iconColor: cs.onTertiaryContainer,
      pageIndex: 0,
      pageController: _pageController,
    );
  }

  Widget _buildToggleExplainerBanner() {
    if (_toggleExplainerDismissed != false) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    Widget stateItem({
      required IconData icon,
      required Color indicatorColor,
      required Color iconColor,
      required String label,
      required String description,
    }) {
      return Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: indicatorColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 14, color: iconColor),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: tt.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface)),
                  Text(description,
                      style: tt.labelSmall?.copyWith(
                          fontSize: 10,
                          color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text('How the toggle works',
                  style: tt.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant)),
              const Spacer(),
              GestureDetector(
                onTap: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('toggle_explainer_dismissed', true);
                  if (mounted) setState(() => _toggleExplainerDismissed = true);
                },
                child: Icon(Icons.close, size: 16, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              stateItem(
                icon: Icons.block_outlined,
                indicatorColor: cs.outlineVariant,
                iconColor: cs.onSurfaceVariant,
                label: 'Off',
                description: 'Not monitored',
              ),
              stateItem(
                icon: Icons.visibility,
                indicatorColor: cs.secondaryContainer,
                iconColor: cs.onSecondaryContainer,
                label: 'Monitor',
                description: 'Silent, no alerts',
              ),
              stateItem(
                icon: Icons.notifications_active,
                indicatorColor: cs.primaryContainer,
                iconColor: cs.onPrimaryContainer,
                label: 'Monitor + Notify',
                description: 'Watched + alerted',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationPermissionBanner() {
    if (_notificationPermissionGranted) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () async {
        await _system.requestNotificationPermission();
        await _checkNotificationPermission();
      },
      child: Container(
        color: Colors.amber.withValues(alpha: 0.15),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: const Row(children: [
          Icon(Icons.notifications_off, color: Colors.amber, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              "Notification permission required — restart alerts won't appear",
              style:
                  TextStyle(color: Colors.amber, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          Text('Tap to fix →', style: TextStyle(color: Colors.amber, fontSize: 12)),
        ]),
      ),
    );
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
              await _requestShizukuPermission();
            },
            child: const Text('Grant Permission'),
          ),
        ],
      ),
    );
  }

  Future<void> _backup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final services = await _storage.loadServices();
      final a11yKeys = await _storage.loadA11yMonitoredKeys();
      final notifKeys = await _storage.loadNotifMonitoredKeys();
      final a11yNotifOff = await _storage.loadA11yNotifOffKeys();
      final notifListenerNotifOff = await _storage.loadNotifListenerNotifOffKeys();
      final events = await _db.getAllEvents();
      final now = DateTime.now();

      final settings = AppBackupSettings(
        useAppColors: prefs.getBool('use_app_colors') ?? false,
        globalIntervalEnabled: prefs.getBool('global_interval_enabled') ?? true,
        defaultCheckInterval: prefs.getInt('default_check_interval') ?? 15,
        useMaterialYou: prefs.getBool('use_material_you') ?? false,
      );

      final data = BackupData(
        version: BackupService.currentVersion,
        exportedAt: now,
        services: services,
        a11yMonitoredKeys: a11yKeys,
        notifMonitoredKeys: notifKeys,
        a11yNotifOffKeys: a11yNotifOff,
        notifListenerNotifOffKeys: notifListenerNotifOff,
        settings: settings,
        auditLog: events.map((e) => e.toMap()).toList(),
      );

      final ts =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/service_keeper_backup_$ts.json');
      await file.writeAsString(BackupService.encode(data));
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'Service Keeper Backup',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _restore() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      final path = result.files.single.path;
      final String content;
      if (bytes != null) {
        content = utf8.decode(bytes);
      } else if (path != null) {
        content = await File(path).readAsString();
      } else {
        return;
      }

      final backup = BackupService.decode(content);

      // Detect installed packages via native bridge
      final appInfo = AppInfoService();
      final installed = await appInfo.getInstalledServices();
      final installedPackages = installed.map((s) => s.packageName).toSet();

      final missingPackages = BackupService.findMissingPackages(
          backup.services, installedPackages);
      final adjustedServices = BackupService.disableMissingServices(
          backup.services, missingPackages);
      final adjustedA11yKeys = BackupService.filterKeysForMissing(
          backup.a11yMonitoredKeys, missingPackages);
      final adjustedNotifKeys = BackupService.filterKeysForMissing(
          backup.notifMonitoredKeys, missingPackages);
      final adjustedA11yNotifOff = BackupService.filterKeysForMissing(
          backup.a11yNotifOffKeys, missingPackages);
      final adjustedNotifListenerNotifOff = BackupService.filterKeysForMissing(
          backup.notifListenerNotifOffKeys, missingPackages);

      if (!mounted) return;
      final currentServices = await _storage.loadServices();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore Backup'),
          content: Text(
            'This will replace:\n'
            '• ${currentServices.length} service${currentServices.length == 1 ? '' : 's'} → ${adjustedServices.length} from backup\n'
            '• Accessibility monitoring: ${adjustedA11yKeys.length} entries\n'
            '• Notification monitoring: ${adjustedNotifKeys.length} entries\n'
            '• App settings will be restored\n'
            '• Audit log: ${backup.auditLog.length} events'
            '${missingPackages.isNotEmpty ? '\n\n⚠ ${missingPackages.length} app${missingPackages.length == 1 ? '' : 's'} not installed — monitoring disabled' : ''}',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
          ],
        ),
      );
      if (ok != true) return;

      // Restore data
      await _storage.saveServices(adjustedServices);
      await _storage.saveA11yMonitoredKeys(adjustedA11yKeys);
      await _storage.saveNotifMonitoredKeys(adjustedNotifKeys);
      await _storage.saveA11yNotifOffKeys(adjustedA11yNotifOff);
      await _storage.saveNotifListenerNotifOffKeys(adjustedNotifListenerNotifOff);
      await _storage.saveRestoredMissingPackages(missingPackages);
      await _db.importAuditEvents(
          backup.auditLog.map((e) => AuditEvent.fromMap(e)).toList());

      // Restore app settings
      final prefs = await SharedPreferences.getInstance();
      final s = backup.settings;
      await prefs.setBool('use_app_colors', s.useAppColors);
      await prefs.setBool('global_interval_enabled', s.globalIntervalEnabled);
      await prefs.setInt('default_check_interval', s.defaultCheckInterval);
      await prefs.setBool('use_material_you', s.useMaterialYou);
      colorfulCardsNotifier.value = s.useAppColors;
      _loadIntervalSetting();

      _refreshCallbacks[0]?.call();
      _refreshCallbacks[1]?.call();
      _refreshCallbacks[2]?.call();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Restored ${adjustedServices.length} services'
              '${missingPackages.isNotEmpty ? ' (${missingPackages.length} missing)' : ''}'
              ' and ${backup.auditLog.length} history events',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _onNavTap(int i) {
    setState(() => _currentIndex = i);
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selectionState != null
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear selection',
                onPressed: () => _selectionState?.onClearSelection(),
              )
            : null,
        title: _selectionState != null
            ? Text('${_selectionState!.count} selected')
            : const Text('Service Keeper'),
        actions: _selectionState != null
            ? [
                IconButton(
                  icon: const Icon(Icons.play_circle_outline),
                  tooltip: 'Restart selected',
                  onPressed: () => _selectionState?.onRestartSelected(),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
switch (v) {
  case 'enable':
    _selectionState?.onEnableSelected();
    break;
  case 'disable':
    _selectionState?.onDisableSelected();
    break;
  case 'configure':
    _selectionState?.onConfigureSelected();
    break;
  case 'select_all':
    _selectionState?.onSelectAll();
    break;
  case 'invert':
    _selectionState?.onInvertSelection();
    break;
  case 'remove':
    _selectionState?.onRemoveSelected();
    break;
}
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'enable', child: Text('Enable monitoring')),
                    const PopupMenuItem(
                        value: 'disable', child: Text('Disable monitoring')),
                    const PopupMenuItem(
                        value: 'configure', child: Text('Configure')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: 'select_all', child: Text('Select all')),
                    const PopupMenuItem(
                        value: 'invert', child: Text('Invert selection')),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ]
            : [
                if (_currentIndex == 0 &&
                    _shizukuStatus == ShizukuStatus.ready) ...[
                  IconButton(
                    icon: const Icon(Icons.play_circle_outline),
                    tooltip: 'Run monitor now',
                    onPressed: () => _runMonitorNow?.call(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Check statuses now',
                    onPressed: () => _checkStatuses?.call(),
                  ),
                ] else if (_currentIndex != 0)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                    onPressed: () => _refreshCallbacks[_currentIndex]?.call(),
                  ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'undo') _undoAction?.call();
                    if (v == 'settings') {
                      Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SettingsScreen()),
                      ).then((bannersReset) async {
                        _loadIntervalSetting();
                        _refreshCallbacks[0]?.call();
                        if (bannersReset == true) {
                          await _reloadBannerStates();
                          _refreshCallbacks[1]?.call();
                          _refreshCallbacks[2]?.call();
                        }
                      });
                    }
                    if (v == 'backup') _backup();
                    if (v == 'restore') _restore();
                    if (v == 'about') {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen()));
                    }
                  },
                  itemBuilder: (_) => [
                    if (_undoAction != null) ...[
                      PopupMenuItem(
                        value: 'undo',
                        child: Row(children: [
                          const Icon(Icons.undo, size: 18),
                          const SizedBox(width: 8),
                          Text('Undo: ${_undoLabel ?? 'last action'}'),
                        ]),
                      ),
                      const PopupMenuDivider(),
                    ],
                    const PopupMenuItem(
                        value: 'settings', child: Text('Settings')),
                    const PopupMenuItem(value: 'backup', child: Text('Backup')),
                    const PopupMenuItem(
                        value: 'restore', child: Text('Restore')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'about', child: Text('About')),
                  ],
                ),
              ],
      ),
      body: Column(
        children: [
          _buildShizukuBanner(),
          _buildBatteryBanner(),
          _buildNotificationPermissionBanner(),
          _buildToggleExplainerBanner(),
          _buildMonitoringExplainerBanner(),
          _buildAppRestartTipBanner(),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _currentIndex = i),
              children: [
                _KeepAlive(
                  child: HomeScreen(
                    shizukuStatus: _shizukuStatus,
                    onRequestShizukuPermission: _requestShizukuPermission,
                    onRegister: ({
                      required VoidCallback refresh,
                      required VoidCallback runMonitorNow,
                      required VoidCallback checkStatuses,
                      required VoidCallback addService,
                    }) {
                      _refreshCallbacks[0] = refresh;
                      _runMonitorNow = runMonitorNow;
                      _checkStatuses = checkStatuses;
                      _addService = addService;
                    },
                    onSelectionChange: (state) =>
                        setState(() => _selectionState = state),
                    onUndoChange: _registerUndo,
                  ),
                ),
                _KeepAlive(
                  child: AccessibilityMonitorScreen(
                    onRegisterRefresh: (cb) => _refreshCallbacks[1] = cb,
                    pageController: _pageController,
                    onUndoChange: _registerUndo,
                  ),
                ),
                _KeepAlive(
                  child: NotificationMonitorScreen(
                    onRegisterRefresh: (cb) => _refreshCallbacks[2] = cb,
                    pageController: _pageController,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0 && _selectionState == null
          ? FloatingActionButton.extended(
              onPressed: _shizukuStatus == ShizukuStatus.ready
                  ? () => _addService?.call()
                  : _showShizukuWarning,
              icon: const Icon(Icons.add),
              label: const Text('Add Service'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onNavTap,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.apps_outlined),
            selectedIcon: Icon(Icons.apps),
            label: 'Services',
          ),
          NavigationDestination(
            icon: Icon(Icons.accessibility_outlined),
            selectedIcon: Icon(Icons.accessibility),
            label: 'Accessibility',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'Notifications',
          ),
        ],
      ),
    );
  }
}

class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
