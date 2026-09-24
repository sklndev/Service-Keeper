import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/shizuku_service.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  final _shizuku = ShizukuService();
  PackageInfo? _info;
  ShizukuStatus? _shizukuStatus;
  DateTime? _shizukuReadySince;
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _info = i);
    });
    _loadShizukuUptime();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadShizukuUptime() async {
    final status = await _shizuku.checkStatus();
    if (!mounted) return;
    if (status != ShizukuStatus.ready) {
      setState(() => _shizukuStatus = status);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt('shizuku_ready_since');
    setState(() {
      _shizukuStatus = status;
      _shizukuReadySince =
          stored != null ? DateTime.fromMillisecondsSinceEpoch(stored) : null;
    });
    if (_shizukuReadySince != null) {
      _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  String _formatUptime() {
    final since = _shizukuReadySince;
    if (since == null) return '';
    final d = DateTime.now().difference(since);
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours.remainder(24)}h ${d.inMinutes.remainder(60)}m';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        children: [
          Center(
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF1E9880), Color(0xFF0D6658)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.all(16),
              child: Image.asset('lib/assets/logo-white-no-bg.png'),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Service Keeper',
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              _info != null
                  ? 'Version ${_info!.version} (build ${_info!.buildNumber})'
                  : '…',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Keeps Android background services alive using Shizuku. '
              'Monitor, restart, and get notified when services stop unexpectedly.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.bolt,
              color: _shizukuStatus == ShizukuStatus.ready ? Colors.green : cs.onSurfaceVariant,
            ),
            title: const Text('Shizuku uptime'),
            subtitle: Text(switch (_shizukuStatus) {
              ShizukuStatus.ready =>
                _shizukuReadySince != null ? _formatUptime() : 'Active',
              ShizukuStatus.permissionDenied => 'Permission denied',
              ShizukuStatus.notRunning => 'Not running',
              ShizukuStatus.notInstalled => 'Not installed',
              null => '…',
            }),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Source code'),
            subtitle: const Text('github.com/sklndev/Service-Keeper'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrl(
              Uri.parse('https://github.com/sklndev/Service-Keeper'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Report a bug'),
            subtitle: const Text('Open an issue on GitHub'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrl(
              Uri.parse('https://github.com/sklndev/Service-Keeper/issues/new'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('Open source licences'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Service Keeper',
              applicationVersion: _info?.version,
            ),
          ),
        ],
      ),
    );
  }
}
