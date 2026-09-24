import 'dart:convert';

enum ServiceState {
  unknown,  // never checked
  running,  // confirmed running
  crashed,  // was running, now unexpectedly not running (monitoring enabled)
  stopped,  // not running because monitoring is disabled
}

class MonitoredService {
  final String packageName;
  final String serviceClass;
  final String displayLabel;
  final String? appName;
  final int intervalMinutes;
  // null = use global interval from settings; set = custom per-service interval
  final int? customIntervalMinutes;
  final bool enabled;
  final DateTime? lastRestarted;
  final DateTime? lastChecked;
  final bool? wasRunning;
  final bool notificationsEnabled;
  final bool appRestartEnabled;

  const MonitoredService({
    required this.packageName,
    required this.serviceClass,
    required this.displayLabel,
    this.appName,
    this.intervalMinutes = 15,
    this.customIntervalMinutes,
    this.enabled = true,
    this.lastRestarted,
    this.lastChecked,
    this.wasRunning,
    this.notificationsEnabled = true,
    this.appRestartEnabled = false,
  });

  String get workTag => '${packageName}_${serviceClass.replaceAll('.', '_')}';

  String get fullServiceName => '$packageName/$serviceClass';

  String get serviceDisplayName {
    final className = serviceClass.split('.').last;
    final label = displayLabel.trim();
    final genericLabels = {
      packageName.toLowerCase(),
      packageName.split('.').last.toLowerCase(),
      if (appName != null) appName!.trim().toLowerCase(),
    };
    if (label.isEmpty || genericLabels.contains(label.toLowerCase())) {
      return className;
    }
    return label;
  }

  ServiceState get state {
    if (wasRunning == null) return ServiceState.unknown;
    if (wasRunning!) return ServiceState.running;
    if (!enabled) return ServiceState.stopped;
    return ServiceState.crashed;
  }

  // Sentinel used to distinguish "pass null explicitly" from "don't change"
  static const _keep = Object();

  MonitoredService copyWith({
    String? packageName,
    String? serviceClass,
    String? displayLabel,
    String? appName,
    int? intervalMinutes,
    // Pass null to clear custom interval (reset to global); omit to keep current.
    Object? customIntervalMinutes = _keep,
    bool? enabled,
    DateTime? lastRestarted,
    DateTime? lastChecked,
    bool? wasRunning,
    bool? notificationsEnabled,
    bool? appRestartEnabled,
  }) {
    return MonitoredService(
      packageName: packageName ?? this.packageName,
      serviceClass: serviceClass ?? this.serviceClass,
      displayLabel: displayLabel ?? this.displayLabel,
      appName: appName ?? this.appName,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      customIntervalMinutes: identical(customIntervalMinutes, _keep)
          ? this.customIntervalMinutes
          : customIntervalMinutes as int?,
      enabled: enabled ?? this.enabled,
      lastRestarted: lastRestarted ?? this.lastRestarted,
      lastChecked: lastChecked ?? this.lastChecked,
      wasRunning: wasRunning ?? this.wasRunning,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      appRestartEnabled: appRestartEnabled ?? this.appRestartEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        'serviceClass': serviceClass,
        'displayLabel': displayLabel,
        'appName': appName,
        'intervalMinutes': intervalMinutes,
        'customIntervalMinutes': customIntervalMinutes,
        'enabled': enabled,
        'lastRestarted': lastRestarted?.toIso8601String(),
        'lastChecked': lastChecked?.toIso8601String(),
        'wasRunning': wasRunning,
        'notificationsEnabled': notificationsEnabled,
        'appRestartEnabled': appRestartEnabled,
      };

  factory MonitoredService.fromJson(Map<String, dynamic> json) {
    final intervalMinutes = json['intervalMinutes'] as int? ?? 15;
    // Migration: old data has no customIntervalMinutes key — preserve their
    // existing interval as custom so nothing changes after the upgrade.
    final customIntervalMinutes = json.containsKey('customIntervalMinutes')
        ? json['customIntervalMinutes'] as int?
        : intervalMinutes;
    return MonitoredService(
      packageName: json['packageName'] as String,
      serviceClass: json['serviceClass'] as String,
      displayLabel: json['displayLabel'] as String,
      appName: json['appName'] as String?,
      intervalMinutes: intervalMinutes,
      customIntervalMinutes: customIntervalMinutes,
      enabled: json['enabled'] as bool? ?? true,
      lastRestarted: json['lastRestarted'] != null
          ? DateTime.parse(json['lastRestarted'] as String)
          : null,
      lastChecked: json['lastChecked'] != null
          ? DateTime.parse(json['lastChecked'] as String)
          : null,
      wasRunning: json['wasRunning'] as bool?,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      appRestartEnabled: json['appRestartEnabled'] as bool? ?? false,
    );
  }

  static List<MonitoredService> listFromJson(String raw) {
    final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => MonitoredService.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String listToJson(List<MonitoredService> services) =>
      jsonEncode(services.map((s) => s.toJson()).toList());

  @override
  bool operator ==(Object other) =>
      other is MonitoredService &&
      packageName == other.packageName &&
      serviceClass == other.serviceClass;

  @override
  int get hashCode => Object.hash(packageName, serviceClass);
}

class RunningService {
  final String packageName;
  final String serviceClass;
  final String? processName;
  final String? appName;
  final bool isRunning;
  final bool isExported;
  final String permission;

  const RunningService({
    required this.packageName,
    required this.serviceClass,
    this.processName,
    this.appName,
    this.isRunning = false,
    this.isExported = true,
    this.permission = '',
  });

  bool get isJobService =>
      permission == 'android.permission.BIND_JOB_SERVICE';

  String get displayServiceClass {
    if (serviceClass.startsWith(packageName)) {
      return serviceClass.substring(packageName.length);
    }
    return serviceClass;
  }

  /// True when the service is part of the app's own codebase (not a library).
  /// Uses the first two package segments as the company prefix (e.g. com.life360)
  /// and excludes well-known third-party library namespaces.
  bool get isAppOwned {
    const libraryPrefixes = [
      'androidx.',
      'com.google.firebase.',
      'com.google.android.gms.',
      'com.google.android.datatransport.',
      'kotlin.',
      'io.flutter.',
      'com.facebook.',
      'com.microsoft.',
      'com.adjust.',
      'com.amplitude.',
      'com.braze.',
      'io.sentry.',
    ];
    if (libraryPrefixes.any((p) => serviceClass.startsWith(p))) return false;
    final parts = packageName.split('.');
    if (parts.length >= 2) {
      return serviceClass.startsWith('${parts[0]}.${parts[1]}.');
    }
    return serviceClass.startsWith(packageName);
  }
}
