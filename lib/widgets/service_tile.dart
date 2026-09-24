import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/monitored_service.dart';

class ServiceTile extends StatefulWidget {
  final MonitoredService service;
  final Uint8List? iconBytes;
  final VoidCallback? onToggle;
  final VoidCallback? onConfigure;
  final VoidCallback? onRemove;
  final VoidCallback? onRestartNow;
  final VoidCallback? onViewHistory;
  final VoidCallback? onCheckDue;
  final VoidCallback? onToggleNotifications;
  final VoidCallback? onReportIssue;
  final Color? accentColor;
  final bool showLeading;
  final bool globalIntervalEnabled;
  final int effectiveIntervalMinutes;
  final bool isRestarting;
  final DateTime now;

  const ServiceTile({
    super.key,
    required this.service,
    this.iconBytes,
    this.onToggle,
    this.onConfigure,
    this.onRemove,
    this.onRestartNow,
    this.onViewHistory,
    this.onCheckDue,
    this.onToggleNotifications,
    this.onReportIssue,
    this.accentColor,
    this.showLeading = true,
    this.globalIntervalEnabled = true,
    this.effectiveIntervalMinutes = 15,
    this.isRestarting = false,
    required this.now,
  });

  @override
  State<ServiceTile> createState() => _ServiceTileState();
}

class _ServiceTileState extends State<ServiceTile>
    with SingleTickerProviderStateMixin {
  bool _checkTriggered = false;
  late final AnimationController _statusAnimation;

  @override
  void initState() {
    super.initState();
    _statusAnimation = AnimationController(
      vsync: this,
    );
    _syncStatusAnimation();
    _maybeTriggerDueCheck();
  }

  @override
  void didUpdateWidget(ServiceTile old) {
    super.didUpdateWidget(old);
    if (old.service.lastChecked != widget.service.lastChecked ||
        old.effectiveIntervalMinutes != widget.effectiveIntervalMinutes ||
        old.globalIntervalEnabled != widget.globalIntervalEnabled ||
        old.service.enabled != widget.service.enabled) {
      _checkTriggered = false;
    }
    if (old.isRestarting != widget.isRestarting ||
        old.service.state != widget.service.state) {
      _syncStatusAnimation();
    }
    _maybeTriggerDueCheck();
  }

  void _syncStatusAnimation() {
    if (widget.isRestarting) {
      _statusAnimation.duration = const Duration(milliseconds: 900);
      _statusAnimation.repeat();
    } else if (widget.service.state == ServiceState.running) {
      _statusAnimation.duration = const Duration(seconds: 1);
      _statusAnimation.repeat();
    } else {
      _statusAnimation
        ..stop()
        ..value = 0;
    }
  }

  void _maybeTriggerDueCheck() {
    if (!widget.globalIntervalEnabled || !widget.service.enabled) return;
    if (widget.service.lastChecked == null) return;
    if (_progressValue(widget.now) <= 0 && !_checkTriggered) {
      _checkTriggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onCheckDue?.call();
      });
    }
  }

  @override
  void dispose() {
    _statusAnimation.dispose();
    super.dispose();
  }

  Color _statusColor(BuildContext context) {
    if (widget.isRestarting) return Colors.orange;
    return switch (widget.service.state) {
      ServiceState.running => Colors.green,
      ServiceState.crashed => Colors.red,
      ServiceState.stopped || ServiceState.unknown => Colors.grey,
    };
  }

  String _statusLabel() {
    if (widget.isRestarting) return 'Restarting';
    return switch (widget.service.state) {
      ServiceState.running => 'Running',
      ServiceState.crashed => 'Not Running',
      ServiceState.stopped => 'Disabled',
      ServiceState.unknown => 'Unknown',
    };
  }

  IconData _statusIcon() {
    if (widget.isRestarting) return Icons.sync_rounded;
    return switch (widget.service.state) {
      ServiceState.running => Icons.circle,
      ServiceState.crashed => Icons.priority_high_rounded,
      ServiceState.stopped => Icons.pause_rounded,
      ServiceState.unknown => Icons.question_mark_rounded,
    };
  }

  String _intervalLabel() {
    final minutes = widget.effectiveIntervalMinutes;
    final suffix = widget.service.customIntervalMinutes != null ? ' (custom)' : '';
    if (minutes < 60) return 'Every ${minutes}m$suffix';
    return 'Every ${minutes ~/ 60}h$suffix';
  }

  double _progressValue(DateTime now) {
    if (!widget.service.enabled) return 0;
    if (widget.service.lastChecked == null) return 1;
    final elapsed = now.difference(widget.service.lastChecked!);
    final interval = Duration(minutes: widget.effectiveIntervalMinutes);
    final remaining = interval - elapsed;
    if (remaining.inSeconds <= 0) return 0;
    return remaining.inSeconds / interval.inSeconds;
  }

  String _nextCheckLabel(DateTime now) {
    if (!widget.service.enabled) return '';
    if (widget.service.lastChecked == null) return 'Pending first check';
    final elapsed = now.difference(widget.service.lastChecked!);
    final remaining = Duration(minutes: widget.effectiveIntervalMinutes) - elapsed;
    if (remaining.inSeconds <= 0) return 'Check pending';
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    if (m >= 60) return 'Next check in ${m ~/ 60}h ${m % 60}m';
    if (m > 0) return 'Next check in ${m}m ${s}s';
    return 'Next check in ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _statusColor(context);
    final progress = _progressValue(widget.now);
    final nextLabel = widget.globalIntervalEnabled ? _nextCheckLabel(widget.now) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.showLeading) ...[
                Stack(
                  children: [
                    widget.iconBytes != null
                        ? CircleAvatar(
                            backgroundImage: MemoryImage(widget.iconBytes!),
                            backgroundColor: Colors.transparent,
                          )
                        : CircleAvatar(
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Text(
                              widget.service.serviceDisplayName.isNotEmpty
                                  ? widget.service.serviceDisplayName[0].toUpperCase()
                                  : '?',
                              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                            ),
                          ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.colorScheme.surface, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Tooltip(
                          message: _statusLabel(),
                          child: Semantics(
                            label: 'Service status: ${_statusLabel()}',
                            child: Container(
                              key: const ValueKey('service-status-badge'),
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: widget.service.state == ServiceState.running &&
                                        !widget.isRestarting
                                    ? Colors.transparent
                                    : statusColor.withValues(alpha: 0.16),
                                shape: BoxShape.circle,
                              ),
                              child: widget.isRestarting
                                  ? RotationTransition(
                                      key: const ValueKey('restart-status-rotation'),
                                      turns: _statusAnimation,
                                      child: Icon(
                                        _statusIcon(),
                                        size: 14,
                                        color: statusColor,
                                      ),
                                    )
                                  : widget.service.state == ServiceState.running
                                      ? AnimatedBuilder(
                                          key: const ValueKey('running-status-pulse'),
                                          animation: _statusAnimation,
                                          builder: (context, _) {
                                            final pingProgress = Curves.easeOutCubic
                                                .transform(
                                                  (_statusAnimation.value / 0.75)
                                                      .clamp(0.0, 1.0),
                                                );
                                            return Stack(
                                              alignment: Alignment.center,
                                              children: [
                                                Opacity(
                                                  key: const ValueKey(
                                                      'running-status-ping-ring'),
                                                  opacity: 0.75 * (1 - pingProgress),
                                                  child: Transform.scale(
                                                    scale: 1 + pingProgress,
                                                    child: Container(
                                                      width: 10,
                                                      height: 10,
                                                      decoration: BoxDecoration(
                                                        color: statusColor,
                                                        shape: BoxShape.circle,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Container(
                                                  key: const ValueKey(
                                                      'running-status-solid-dot'),
                                                  width: 8,
                                                  height: 8,
                                                  decoration: BoxDecoration(
                                                    color: statusColor,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        )
                                  : Icon(
                                      _statusIcon(),
                                      size: 14,
                                      color: statusColor,
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            widget.service.serviceDisplayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          key: const ValueKey('service-notification-toggle'),
                          onPressed: widget.onToggleNotifications,
                          tooltip: widget.service.notificationsEnabled
                              ? 'Disable notifications'
                              : 'Enable notifications',
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          icon: Icon(
                            widget.service.notificationsEnabled
                                ? Icons.notifications
                                : Icons.notifications_off,
                            size: 17,
                            color: widget.service.notificationsEnabled
                                ? (widget.accentColor ?? theme.colorScheme.primary)
                                : theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ),
                    if (widget.globalIntervalEnabled) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.schedule, size: 12, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          _intervalLabel(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: widget.service.customIntervalMinutes != null
                                ? theme.colorScheme.tertiary
                                : theme.colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ]),
                    ],
                    if (nextLabel.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        nextLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                    if (widget.service.state == ServiceState.crashed &&
                        !widget.service.appRestartEnabled) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 11,
                              color: theme.colorScheme.error.withValues(alpha: 0.8)),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              'Enable app restart fallback in App settings to recover this service.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 10,
                                color: theme.colorScheme.error.withValues(alpha: 0.8),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.scale(
                    scale: 0.75,
                    alignment: Alignment.centerRight,
                    child: Switch(
                      value: widget.service.enabled,
                      onChanged: widget.onToggle != null ? (_) => widget.onToggle!() : null,
                      thumbColor: widget.accentColor == null
                          ? null
                          : WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return ThemeData.estimateBrightnessForColor(widget.accentColor!) ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black87;
                              }
                              return null;
                            }),
                      trackColor: widget.accentColor == null
                          ? null
                          : WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return widget.accentColor;
                              }
                              return null;
                            }),
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'configure') widget.onConfigure?.call();
                      if (v == 'restart') widget.onRestartNow?.call();
                      if (v == 'history') widget.onViewHistory?.call();
                      if (v == 'toggle_notifications') widget.onToggleNotifications?.call();
                      if (v == 'report_issue') widget.onReportIssue?.call();
                      if (v == 'remove') widget.onRemove?.call();
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'configure', child: Text('Configure')),
                      const PopupMenuItem(value: 'restart', child: Text('Restart now')),
                      const PopupMenuItem(value: 'history', child: Text('View history')),
                      PopupMenuItem(
                        value: 'toggle_notifications',
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Notifications'),
                            IgnorePointer(
                              child: Transform.scale(
                                scale: 0.8,
                                alignment: Alignment.centerRight,
                                child: Switch(
                                  value: widget.service.notificationsEnabled,
                                  onChanged: (_) {},
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'report_issue',
                        child: Row(
                          children: [
                            Icon(Icons.bug_report_outlined, size: 16),
                            SizedBox(width: 8),
                            Text('Report Issue'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove', style: TextStyle(color: Colors.red))),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        if (widget.globalIntervalEnabled && widget.service.enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: progress),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              builder: (context, animatedProgress, _) {
                final baseColor = widget.accentColor ?? theme.colorScheme.primary;
                final activeColor = animatedProgress < 0.15
                    ? theme.colorScheme.error
                    : animatedProgress < 0.35
                        ? theme.colorScheme.tertiary
                        : baseColor;
                return ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: animatedProgress,
                    minHeight: 6,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    color: activeColor,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
