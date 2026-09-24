import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:service_keeper/widgets/page_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_settings_notifier.dart';
import '../services/app_info_service.dart';
import '../services/database_service.dart';
import '../services/diagnostics_service.dart';
import '../services/shizuku_service.dart';
import '../services/storage_service.dart';
import '../services/system_service.dart';
import '../widgets/app_group_card.dart';
import 'service_audit_screen.dart';

class NotificationMonitorScreen extends StatefulWidget {
  final void Function(VoidCallback refresh) onRegisterRefresh;
  final PageController? pageController;

  const NotificationMonitorScreen({
    super.key,
    required this.onRegisterRefresh,
    this.pageController,
  });

  @override
  State<NotificationMonitorScreen> createState() => _NotificationMonitorScreenState();
}

class _NotificationMonitorScreenState extends State<NotificationMonitorScreen>
    with WidgetsBindingObserver {
  final _appInfo = AppInfoService();
  final _db = DatabaseService();
  final _shizuku = ShizukuService();
  final _storage = StorageService();
  final _system = SystemService();

  List<({String packageName, String serviceClass, String appName, bool exported, String permission})>
      _notifServices = [];
  Set<String> _enabledKeys = {};
  Set<String> _monitoredKeys = {};
  Set<String> _notifOffKeys = {};
  Map<String, Uint8List?> _iconCache = {};
  Map<String, Color> _colorCache = {};
  Map<String, bool> _expandedGroups = {};
  bool _useAppColors = false;
  bool _loading = true;
  bool _permInfoDismissed = false;
  bool _revokeBannerDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    colorfulCardsNotifier.addListener(_onColorfulCardsChanged);
    widget.onRegisterRefresh(_load);
    _load();
  }

  @override
  void dispose() {
    colorfulCardsNotifier.removeListener(_onColorfulCardsChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onColorfulCardsChanged() {
    if (!mounted) return;
    setState(() => _useAppColors = colorfulCardsNotifier.value);
    if (_useAppColors) _generateColors();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshEnabledState();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    _useAppColors = prefs.getBool('use_app_colors') ?? false;

    final all = await _appInfo.getInstalledServices();
    final notif = all
        .where((s) =>
            s.permission == 'android.permission.BIND_NOTIFICATION_LISTENER_SERVICE')
        .toList();

    final enabled = await _system.getEnabledNotificationListeners();
    var monKeys = await _storage.loadNotifMonitoredKeys();
    final notifOff = await _storage.loadNotifListenerNotifOffKeys();

    final newKeys = enabled
        .where((k) =>
            !monKeys.contains(k) &&
            notif.any((s) => '${s.packageName}/${s.serviceClass}' == k))
        .toSet();
    if (newKeys.isNotEmpty) {
      monKeys = {...monKeys, ...newKeys};
      for (final k in newKeys) {
        final slash = k.indexOf('/');
        if (slash >= 0) {
          await _storage.addNotifMonitored(k.substring(0, slash), k.substring(slash + 1));
        }
      }
    }

    final validKeys = notif.map((s) => '${s.packageName}/${s.serviceClass}').toSet();
    final staleKeys = monKeys.where((k) => !validKeys.contains(k)).toSet();
    if (staleKeys.isNotEmpty) {
      monKeys = monKeys.difference(staleKeys);
      for (final k in staleKeys) {
        final slash = k.indexOf('/');
        if (slash >= 0) {
          await _storage.removeNotifMonitored(k.substring(0, slash), k.substring(slash + 1));
        }
      }
    }

    if (mounted) {
      setState(() {
        _notifServices = notif;
        _enabledKeys = enabled;
        _monitoredKeys = monKeys;
        _notifOffKeys = notifOff;
        _permInfoDismissed = prefs.getBool('notif_perm_info_dismissed') ?? false;
        _revokeBannerDismissed = prefs.getBool('notif_revoke_banner_dismissed') ?? false;
        _loading = false;
        for (final s in notif) {
          _expandedGroups.putIfAbsent(s.packageName, () => false);
        }
      });
    }
    await _fetchIcons(notif.map((s) => s.packageName).toSet());
    if (_useAppColors) _generateColors();
  }

  Future<void> _refreshEnabledState() async {
    final prev = Set<String>.from(_enabledKeys);
    final enabled = await _system.getEnabledNotificationListeners();
    if (!mounted) return;
    final newlyEnabled = enabled
        .difference(prev)
        .where((k) => _notifServices.any((s) => '${s.packageName}/${s.serviceClass}' == k))
        .toSet();
    final revoked = prev.difference(enabled).where(_monitoredKeys.contains).toSet();
    setState(() {
      _enabledKeys = enabled;
      if (newlyEnabled.isNotEmpty) _monitoredKeys = {..._monitoredKeys, ...newlyEnabled};
      if (revoked.isNotEmpty) _monitoredKeys = Set.from(_monitoredKeys)..removeAll(revoked);
    });
    for (final k in newlyEnabled) {
      final slash = k.indexOf('/');
      if (slash >= 0) await _storage.addNotifMonitored(k.substring(0, slash), k.substring(slash + 1));
    }
    for (final k in revoked) {
      final slash = k.indexOf('/');
      if (slash >= 0) await _storage.removeNotifMonitored(k.substring(0, slash), k.substring(slash + 1));
    }
  }

  Future<void> _fetchIcons(Set<String> packages) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = <String, Uint8List?>{};
    for (final pkg in packages) {
      final b64 = prefs.getString('app_icon_v1_$pkg');
      if (b64 != null) cached[pkg] = base64Decode(b64);
    }
    if (mounted && cached.isNotEmpty) setState(() => _iconCache = {..._iconCache, ...cached});

    final missing = packages.where((p) => !cached.containsKey(p)).toSet();
    for (final pkg in missing) {
      final bytes = await _appInfo.getAppIcon(pkg);
      if (bytes != null) {
        await prefs.setString('app_icon_v1_$pkg', base64Encode(bytes));
        if (mounted) setState(() => _iconCache[pkg] = bytes);
      }
    }
    if (_useAppColors) _generateColors();
  }

  Future<void> _generateColors() async {
    final prefs = await SharedPreferences.getInstance();
    for (final pkg in _iconCache.keys) {
      if (_colorCache.containsKey(pkg)) continue;
      final cached = prefs.getInt('app_color_v1_$pkg');
      if (cached != null && mounted) {
        setState(() => _colorCache[pkg] = Color(cached));
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
          if (mounted) setState(() => _colorCache[pkg] = color);
        }
      } catch (_) {}
    }
  }

  Future<void> _toggle(String packageName, String serviceClass, String appName) async {
    final key = '$packageName/$serviceClass';
    final nowMonitored = !_monitoredKeys.contains(key);
    setState(() {
      if (nowMonitored)
        _monitoredKeys.add(key);
      else
        _monitoredKeys.remove(key);
    });
    if (nowMonitored) {
      await _storage.addNotifMonitored(packageName, serviceClass);
    } else {
      await _storage.removeNotifMonitored(packageName, serviceClass);
    }
    if (mounted) {
      final label = serviceClass.split('.').last;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(nowMonitored ? 'Now monitoring $label' : 'Stopped monitoring $label'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _setGroupState(
      String packageName,
      List<({String serviceClass, String appName})> services,
      int state) async {
    if (state == 0) {
      setState(() {
        for (final s in services) {
          final key = '$packageName/${s.serviceClass}';
          _monitoredKeys.remove(key);
          _notifOffKeys.remove(key);
        }
      });
      for (final s in services) {
        await _storage.removeNotifMonitored(packageName, s.serviceClass);
        await _storage.clearNotifListenerNotifOff(packageName, s.serviceClass);
      }
    } else {
      final applicable = services
          .where((s) => _enabledKeys.contains('$packageName/${s.serviceClass}'))
          .toList();
      final alreadyMonitored = services
          .where((s) => _monitoredKeys.contains('$packageName/${s.serviceClass}'))
          .toList();
      if (applicable.isEmpty && alreadyMonitored.isEmpty) {
        await _showPermissionRequiredDialog(
            packageName, services.first.serviceClass, services.first.appName);
        if (mounted) setState(() {});
        return;
      }
      setState(() {
        for (final s in applicable) {
          _monitoredKeys.add('$packageName/${s.serviceClass}');
        }
        for (final s in services) {
          final key = '$packageName/${s.serviceClass}';
          if (state == 1) {
            _notifOffKeys.add(key);
          } else {
            _notifOffKeys.remove(key);
          }
        }
      });
      for (final s in applicable) {
        await _storage.addNotifMonitored(packageName, s.serviceClass);
      }
      for (final s in services) {
        if (state == 1) {
          await _storage.setNotifListenerNotifOff(packageName, s.serviceClass);
        } else {
          await _storage.clearNotifListenerNotifOff(packageName, s.serviceClass);
        }
      }
    }
  }

  Future<void> _showPermissionRequiredDialog(
      String packageName, String serviceClass, String appName) async {
    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permission Required'),
        content: Text(
          '$appName needs its Notification Listener permission granted in Android Settings '
          'before Service Keeper can monitor it.\n\nOpen Android Settings now?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open Settings')),
        ],
      ),
    );
    if (result == true && mounted) {
      await _system.openNotificationListenerSettings(
          packageName: packageName, serviceClass: serviceClass);
    }
  }

  Future<void> _reportServiceIssue(
    String packageName,
    String appName,
    String serviceClass,
  ) async {
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
          Text('Gathering diagnostics...'),
        ]),
      ),
    );

    try {
      final key = '$packageName/$serviceClass';
      final body = await diag.buildExternalServiceReport(
        reportType: 'Notification Listener',
        packageName: packageName,
        appName: appName,
        serviceClass: serviceClass,
        isMonitored: _monitoredKeys.contains(key),
        isEnabled: _enabledKeys.contains(key),
        notificationsEnabled: !_notifOffKeys.contains(key),
      );
      if (!mounted) return;
      if (loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingOpen = false;
      }
      final label = serviceClass.split('.').last;
      final title = 'Notification listener issue: $label ($packageName)';
      await DiagnosticsService.openGitHubIssue(context, title: title, body: body);
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
    String packageName,
    String appName,
    List<({String serviceClass, String appName})> services,
  ) async {
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
          Text('Gathering diagnostics...'),
        ]),
      ),
    );

    try {
      final snapshots = services.map((svc) {
        final key = '$packageName/${svc.serviceClass}';
        return DiagnosticsReportService(
          displayLabel: svc.serviceClass.split('.').last,
          serviceClass: svc.serviceClass,
          isMonitored: _monitoredKeys.contains(key),
          isEnabled: _enabledKeys.contains(key),
          notificationsEnabled: !_notifOffKeys.contains(key),
        );
      }).toList();

      final body = await diag.buildExternalAppReport(
        reportType: 'Notification Listeners',
        packageName: packageName,
        appName: appName,
        services: snapshots,
      );

      if (!mounted) return;
      if (loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingOpen = false;
      }
      final title = 'Notification listeners issue: $appName ($packageName)';
      await DiagnosticsService.openGitHubIssue(context, title: title, body: body);
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

  Map<String, List<({String serviceClass, String appName})>> _grouped() {
    final groups = <String, List<({String serviceClass, String appName})>>{};
    for (final s in _notifServices) {
      groups.putIfAbsent(s.packageName, () => []).add((
        serviceClass: s.serviceClass,
        appName: s.appName,
      ));
    }
    return groups;
  }

  Iterable<({String serviceClass, String appName})> _monitoredServices(
      String pkg, List<({String serviceClass, String appName})> services) {
    return services.where((s) => _monitoredKeys.contains('$pkg/${s.serviceClass}'));
  }

  int _groupState(String pkg, List<({String serviceClass, String appName})> services) {
    final monitored = _monitoredServices(pkg, services).toList();
    if (monitored.isEmpty) return 0;
    final allNotifOff =
        monitored.every((s) => _notifOffKeys.contains('$pkg/${s.serviceClass}'));
    return allNotifOff ? 1 : 2;
  }

  bool _hasIssue(String pkg, List<({String serviceClass, String appName})> services) {
    final monitored = _monitoredServices(pkg, services).toList();
    final activeMonitored =
        monitored.where((s) => _enabledKeys.contains('$pkg/${s.serviceClass}')).length;
    return monitored.isNotEmpty && activeMonitored < monitored.length;
  }

  String _subtitle(String pkg, List<({String serviceClass, String appName})> services) {
    return _monitoredServices(pkg, services).isEmpty
        ? 'Not monitored'
        : 'Monitoring enabled';
  }

  Widget _buildServiceTile(
    String pkg,
    ({String serviceClass, String appName}) svc,
  ) {
    final key = '$pkg/${svc.serviceClass}';
    final enabled = _enabledKeys.contains(key);
    final monitored = _monitoredKeys.contains(key);
    final appColor = _useAppColors ? _colorCache[pkg] : null;
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
      title: Text(
        svc.serviceClass.split('.').last,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            svc.serviceClass,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 3),
          _StatusChip(enabled: enabled),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: enabled ? 1.0 : 0.45,
            child: Transform.scale(
              scale: 0.8,
              alignment: Alignment.centerRight,
              child: Switch(
                value: monitored,
                thumbColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected) ? appColor : null),
                trackColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected)
                        ? appColor?.withValues(alpha: 0.5)
                        : null),
                onChanged: (_) {
                  if (!enabled) {
                    _showPermissionRequiredDialog(pkg, svc.serviceClass, svc.appName);
                  } else {
                    _toggle(pkg, svc.serviceClass, svc.appName);
                  }
                },
              ),
            ),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 18, color: theme.colorScheme.onSurfaceVariant),
            padding: EdgeInsets.zero,
            onSelected: (v) {
              if (v == 'history') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ServiceAuditScreen.forNotification(
                      packageName: pkg,
                      serviceClass: svc.serviceClass,
                      appName: svc.appName,
                    ),
                  ),
                );
              } else if (v == 'manage_permission') {
                _system.openNotificationListenerSettings(
                    packageName: pkg, serviceClass: svc.serviceClass);
              } else if (v == 'report_issue') {
                _reportServiceIssue(pkg, svc.appName, svc.serviceClass);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'history',
                child: Row(children: [
                  Icon(Icons.history, size: 18),
                  SizedBox(width: 8),
                  Text('History'),
                ]),
              ),
              PopupMenuItem(
                value: 'manage_permission',
                child: Row(children: [
                  Icon(Icons.security_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Manage permission'),
                ]),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'report_issue',
                child: Row(children: [
                  Icon(Icons.bug_report_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Report Issue'),
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _grouped();
    final pkgs = groups.keys.toList()
      ..sort((a, b) {
        final an = groups[a]!.first.appName.toLowerCase();
        final bn = groups[b]!.first.appName.toLowerCase();
        return an.compareTo(bn);
      });

    if (_loading) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        PageBanner(
          pref: 'notif_perm_info_dismissed',
          dismissed: _permInfoDismissed,
          text: 'The apps listed here support Notification Listeners. '
              'Before Service Keeper can monitor one, its permission must be granted in Android Settings.',
          onDismiss: () async {
            if (mounted) setState(() => _permInfoDismissed = true);
          },
          icon: Icons.open_in_browser_outlined,
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
          textColor: Theme.of(context).colorScheme.onSecondaryContainer,
          pageIndex: 2,
          pageController: widget.pageController,
        ),
        PageBanner(
          pref: 'notif_revoke_banner_dismissed',
          dismissed: _revokeBannerDismissed,
          text: 'Disabling monitoring here does not revoke the app\'s Android notification listener permission. '
              'To revoke, go to Android Settings.',
          icon: Icons.info,
          onDismiss: () async {
            if (mounted) setState(() => _revokeBannerDismissed = true);
          },
          color: Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.45),
          textColor: Theme.of(context).colorScheme.onTertiaryContainer,
          pageIndex: 2,
          pageController: widget.pageController,
        ),
        Expanded(
          child: pkgs.isEmpty
              ? const Center(child: Text('No third-party notification listeners found.'))
              : CustomScrollView(
                  slivers: [
                    for (final pkg in pkgs) ...[
                      AppGroupCard(
                        key: ValueKey(pkg),
                        expanded: _expandedGroups[pkg] ?? false,
                        onToggleExpanded: () => setState(
                            () => _expandedGroups[pkg] = !(_expandedGroups[pkg] ?? false)),
                        packageName: pkg,
                        appName: groups[pkg]!.first.appName,
                        serviceCount: _monitoredServices(pkg, groups[pkg]!).length,
                        iconBytes: _iconCache[pkg],
                        appColor: _useAppColors ? _colorCache[pkg] : null,
                        subtitle: _subtitle(pkg, groups[pkg]!),
                        groupState: _groupState(pkg, groups[pkg]!),
                        hasIssue: _hasIssue(pkg, groups[pkg]!),
                        onGroupStateChanged: (state) =>
                            _setGroupState(pkg, groups[pkg]!, state),
                        menuItems: const [
                          PopupMenuItem(
                            value: 'history',
                            child: Row(children: [
                              Icon(Icons.history, size: 18),
                              SizedBox(width: 8),
                              Text('History'),
                            ]),
                          ),
                          PopupMenuItem(
                            value: 'manage_permission',
                            child: Row(children: [
                              Icon(Icons.security_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('Manage permission'),
                            ]),
                          ),
                          PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'report_issue',
                            child: Row(children: [
                              Icon(Icons.bug_report_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('Report Issue'),
                            ]),
                          ),
                        ],
                        onMenuSelected: (v) {
                          if (v == 'history') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ServiceAuditScreen.forApp(
                                  packageName: pkg,
                                  appName: groups[pkg]!.first.appName,
                                ),
                              ),
                            );
                          } else if (v == 'manage_permission') {
                            _system.openNotificationListenerSettings(packageName: pkg);
                          } else if (v == 'report_issue') {
                            _reportAppIssue(pkg, groups[pkg]!.first.appName, groups[pkg]!);
                          }
                        },
                        children: [
                          for (final svc in groups[pkg]!)
                            _buildServiceTile(pkg, svc),
                        ],
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool enabled;

  const _StatusChip({required this.enabled});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const activeColor = Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (enabled ? activeColor : cs.surfaceContainerHighest).withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(enabled ? Icons.check_circle : Icons.cancel,
            size: 11, color: enabled ? activeColor : cs.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(
          enabled ? 'Active' : 'Inactive',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: enabled ? activeColor : cs.onSurfaceVariant,
          ),
        ),
      ]),
    );
  }
}
