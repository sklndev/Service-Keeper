import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:service_keeper/widgets/app_group_card.dart';
import 'package:service_keeper/widgets/page_banner.dart';
import 'package:service_keeper/widgets/undo_snack_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_settings_notifier.dart';
import '../services/app_info_service.dart';
import '../services/database_service.dart';
import '../services/diagnostics_service.dart';
import '../services/shizuku_service.dart';
import '../services/storage_service.dart';
import '../services/system_service.dart';
import 'service_audit_screen.dart';

class AccessibilityMonitorScreen extends StatefulWidget {
  final void Function(VoidCallback refresh) onRegisterRefresh;
  final PageController? pageController;
  final void Function(String? label, VoidCallback? action)? onUndoChange;

  const AccessibilityMonitorScreen({
    super.key,
    required this.onRegisterRefresh,
    this.pageController,
    this.onUndoChange,
  });

  @override
  State<AccessibilityMonitorScreen> createState() =>
      _AccessibilityMonitorScreenState();
}

class _AccessibilityMonitorScreenState extends State<AccessibilityMonitorScreen>
    with WidgetsBindingObserver {
  final _appInfo = AppInfoService();
  final _db = DatabaseService();
  final _shizuku = ShizukuService();
  final _storage = StorageService();
  final _system = SystemService();

  List<({String packageName, String serviceClass, String appName, bool exported, String permission})>
      _a11yServices = [];
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
    final a11y = all
        .where((s) => s.permission == 'android.permission.BIND_ACCESSIBILITY_SERVICE')
        .toList();

    final enabled = await _system.getEnabledAccessibilityServices();
    var monKeys = await _storage.loadA11yMonitoredKeys();
    final notifOff = await _storage.loadA11yNotifOffKeys();

    final newKeys = enabled
        .where((k) =>
            !monKeys.contains(k) && a11y.any((s) => '${s.packageName}/${s.serviceClass}' == k))
        .toSet();
    if (newKeys.isNotEmpty) {
      monKeys = {...monKeys, ...newKeys};
      for (final k in newKeys) {
        final slash = k.indexOf('/');
        if (slash >= 0) {
          await _storage.addA11yMonitored(k.substring(0, slash), k.substring(slash + 1));
        }
      }
    }

    final validKeys = a11y.map((s) => '${s.packageName}/${s.serviceClass}').toSet();
    final staleKeys = monKeys.where((k) => !validKeys.contains(k)).toSet();
    if (staleKeys.isNotEmpty) {
      monKeys = monKeys.difference(staleKeys);
      for (final k in staleKeys) {
        final slash = k.indexOf('/');
        if (slash >= 0) {
          await _storage.removeA11yMonitored(k.substring(0, slash), k.substring(slash + 1));
        }
      }
    }

    if (mounted) {
      setState(() {
        _a11yServices = a11y;
        _enabledKeys = enabled;
        _monitoredKeys = monKeys;
        _notifOffKeys = notifOff;
        _permInfoDismissed = prefs.getBool('a11y_perm_info_dismissed') ?? false;
        _revokeBannerDismissed = prefs.getBool('a11y_revoke_banner_dismissed') ?? false;
        _loading = false;
        for (final pkg in a11y.map((s) => s.packageName).toSet()) {
          _expandedGroups.putIfAbsent(pkg, () => false);
        }
      });
    }
    await _fetchIcons(a11y.map((s) => s.packageName).toSet());
    if (_useAppColors) _generateColors();
  }

  Future<void> _refreshEnabledState() async {
    final prev = Set<String>.from(_enabledKeys);
    final enabled = await _system.getEnabledAccessibilityServices();
    if (!mounted) return;
    final newlyEnabled = enabled
        .difference(prev)
        .where((k) => _a11yServices.any((s) => '${s.packageName}/${s.serviceClass}' == k))
        .toSet();
    final revoked = prev.difference(enabled).where(_monitoredKeys.contains).toSet();
    setState(() {
      _enabledKeys = enabled;
      if (newlyEnabled.isNotEmpty) _monitoredKeys = {..._monitoredKeys, ...newlyEnabled};
      if (revoked.isNotEmpty) _monitoredKeys = Set.from(_monitoredKeys)..removeAll(revoked);
    });
    for (final k in newlyEnabled) {
      final slash = k.indexOf('/');
      if (slash >= 0) await _storage.addA11yMonitored(k.substring(0, slash), k.substring(slash + 1));
    }
    for (final k in revoked) {
      final slash = k.indexOf('/');
      if (slash >= 0) await _storage.removeA11yMonitored(k.substring(0, slash), k.substring(slash + 1));
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
      await _storage.addA11yMonitored(packageName, serviceClass);
    } else {
      await _storage.removeA11yMonitored(packageName, serviceClass);
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
    final prevMonitored = Set<String>.from(_monitoredKeys);
    final prevNotifOff = Set<String>.from(_notifOffKeys);

    if (state == 0) {
      setState(() {
        for (final s in services) {
          final key = '$packageName/${s.serviceClass}';
          _monitoredKeys.remove(key);
          _notifOffKeys.add(key);
        }
      });
      for (final s in services) {
        await _storage.removeA11yMonitored(packageName, s.serviceClass);
        await _storage.setA11yNotifOff(packageName, s.serviceClass);
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
        await _storage.addA11yMonitored(packageName, s.serviceClass);
      }
      for (final s in services) {
        if (state == 1) {
          await _storage.setA11yNotifOff(packageName, s.serviceClass);
        } else {
          await _storage.clearA11yNotifOff(packageName, s.serviceClass);
        }
      }
    }
    if (!mounted) return;
    final appName = services.first.appName;
    final label = state == 0 ? 'Disabled' : state == 1 ? 'Monitor' : 'Notify';
    final message = '$appName: $label';

    Future<void> undoFn() async {
      setState(() {
        _monitoredKeys = prevMonitored;
        _notifOffKeys = prevNotifOff;
      });
      for (final s in services) {
        final key = '$packageName/${s.serviceClass}';
        if (prevMonitored.contains(key)) {
          await _storage.addA11yMonitored(packageName, s.serviceClass);
        } else {
          await _storage.removeA11yMonitored(packageName, s.serviceClass);
        }
        if (prevNotifOff.contains(key)) {
          await _storage.setA11yNotifOff(packageName, s.serviceClass);
        } else {
          await _storage.clearA11yNotifOff(packageName, s.serviceClass);
        }
      }
      widget.onUndoChange?.call(null, null);
    }

    widget.onUndoChange?.call(message, undoFn);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(buildUndoSnackBar(message: message, onUndo: undoFn));
  }

  Future<void> _showPermissionRequiredDialog(
      String packageName, String serviceClass, String appName) async {
    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permission Required'),
        content: Text(
          '$appName needs its Accessibility Service permission granted in Android Settings '
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
      await _system.openAccessibilitySettings(
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
        reportType: 'Accessibility Service',
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
      final title = 'Accessibility service issue: $label ($packageName)';
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
        reportType: 'Accessibility Services',
        packageName: packageName,
        appName: appName,
        services: snapshots,
      );

      if (!mounted) return;
      if (loadingOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingOpen = false;
      }
      final title = 'Accessibility services issue: $appName ($packageName)';
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
    for (final s in _a11yServices) {
      groups.putIfAbsent(s.packageName, () => []).add((
        serviceClass: s.serviceClass,
        appName: s.appName,
      ));
    }
    return groups;
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

    final bannersContent = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PageBanner(
          pref: 'a11y_perm_info_dismissed',
          dismissed: _permInfoDismissed,
          text: 'The apps listed here support Accessibility Services. '
              'Before Service Keeper can monitor one, its permission must be granted in Android Settings.',
          onDismiss: () async {
            if (mounted) setState(() => _permInfoDismissed = true);
          },
          icon: Icons.lock_open,
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
          textColor: Theme.of(context).colorScheme.onSecondaryContainer,
          pageIndex: 1,
          pageController: widget.pageController,
        ),
        PageBanner(
          pref: 'a11y_revoke_banner_dismissed',
          dismissed: _revokeBannerDismissed,
          text: 'Disabling monitoring here does not revoke the app\'s Android accessibility permission. '
              'To revoke, go to Android Settings.',
          onDismiss: () async {
            if (mounted) setState(() => _revokeBannerDismissed = true);
          },
          icon: Icons.lock_open,
          color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.4),
          textColor: Theme.of(context).colorScheme.onSecondaryContainer,
          pageIndex: 1,
          pageController: widget.pageController,
        ),
      ],
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: bannersContent),
        if (pkgs.isEmpty)
          const SliverFillRemaining(
            child: Center(child: Text('No third-party accessibility services found.')),
          )
        else
          ...pkgs.map((pkg) {
            final services = groups[pkg]!;
            final appColor = _useAppColors ? _colorCache[pkg] : null;

            final monitoredCount = services
                .where((s) => _monitoredKeys.contains('$pkg/${s.serviceClass}'))
                .length;
            final activeMonitored = services
                .where((s) =>
                    _monitoredKeys.contains('$pkg/${s.serviceClass}') &&
                    _enabledKeys.contains('$pkg/${s.serviceClass}'))
                .length;
            final hasIssue = monitoredCount > 0 && activeMonitored < monitoredCount;
            final monitoredSvcs =
                services.where((s) => _monitoredKeys.contains('$pkg/${s.serviceClass}'));
            final allMonitoredNotifOff = monitoredSvcs.isNotEmpty &&
                monitoredSvcs.every((s) => _notifOffKeys.contains('$pkg/${s.serviceClass}'));
            final groupState = monitoredCount == 0 ? 0 : allMonitoredNotifOff ? 1 : 2;

            final subtitle = monitoredCount == 0
              ? 'Not monitored'
              : '$activeMonitored active';

            return AppGroupCard(
              key: ValueKey(pkg),
              expanded: _expandedGroups[pkg] ?? false,
              onToggleExpanded: () => setState(
                  () => _expandedGroups[pkg] = !(_expandedGroups[pkg] ?? false)),
              packageName: pkg,
              appName: services.first.appName,
              serviceCount: monitoredCount,
              iconBytes: _iconCache[pkg],
              appColor: appColor,
              subtitle: subtitle,
              groupState: groupState,
              hasIssue: hasIssue,
              onGroupStateChanged: (state) => _setGroupState(pkg, services, state),
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
                        appName: services.first.appName,
                      ),
                    ),
                  );
                } else if (v == 'manage_permission') {
                  _system.openAccessibilitySettings(packageName: pkg);
                } else if (v == 'report_issue') {
                  _reportAppIssue(pkg, services.first.appName, services);
                }
              },
              children: [
                for (final svc in services) _buildServiceTile(context, pkg, svc, appColor),
              ],
            );
          }),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _buildServiceTile(
    BuildContext context,
    String pkg,
    ({String serviceClass, String appName}) svc,
    Color? appColor,
  ) {
    final key = '$pkg/${svc.serviceClass}';
    final enabled = _enabledKeys.contains(key);
    final monitored = _monitoredKeys.contains(key);
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
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
          Icon(
            _notifOffKeys.contains(key) ? Icons.notifications_off : Icons.notifications,
            size: 16,
            color: _notifOffKeys.contains(key)
                ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                : (appColor ?? theme.colorScheme.primary),
          ),
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
                    builder: (_) => ServiceAuditScreen.forAccessibility(
                      packageName: pkg,
                      serviceClass: svc.serviceClass,
                      appName: svc.appName,
                    ),
                  ),
                );
              } else if (v == 'manage_permission') {
                _system.openAccessibilitySettings(
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
