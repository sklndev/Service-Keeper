import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Sliver-based expandable app group card.
/// Must be placed inside a [CustomScrollView]'s slivers list.
/// Caller owns the [expanded] state to preserve it across scroll recycling.
class AppGroupCard extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final String packageName;
  final String appName;
  final int serviceCount;
  final Uint8List? iconBytes;
  final Color? appColor;
  final String subtitle;

  /// 3-state toggle: 0 = disabled, 1 = monitor (silent), 2 = notify.
  /// Pass null to hide the toggle entirely.
  final int? groupState;
  final bool hasIssue;
  final void Function(int)? onGroupStateChanged;

  final List<PopupMenuEntry<String>> menuItems;
  final void Function(String) onMenuSelected;
  final List<Widget> children;

  /// Optional widget to override the default icon/avatar.
  final Widget? icon;

  /// Called on long-press (normal mode) or on tap (selection mode).
  final VoidCallback? onSelect;

  final bool isInSelectionMode;
  final bool isSelected;
  final bool isPartiallySelected;
  final bool isRestoredMissing;

  const AppGroupCard({
    super.key,
    required this.expanded,
    required this.onToggleExpanded,
    required this.packageName,
    required this.appName,
    required this.serviceCount,
    this.iconBytes,
    this.appColor,
    required this.subtitle,
    this.groupState,
    this.hasIssue = false,
    this.onGroupStateChanged,
    required this.menuItems,
    required this.onMenuSelected,
    required this.children,
    this.icon,
    this.onSelect,
    this.isInSelectionMode = false,
    this.isSelected = false,
    this.isPartiallySelected = false,
    this.isRestoredMissing = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    final bodyBg = appColor == null
        ? theme.colorScheme.surfaceContainerLow
        : Color.alphaBlend(
            appColor!.withValues(alpha: dark ? 0.22 : 0.10),
            dark ? const Color(0xFF1C1C1C) : Colors.white,
          );

    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: expanded,
          delegate: _AppGroupCardHeaderDelegate(
            expanded: expanded,
            onToggleExpanded: onToggleExpanded,
            packageName: packageName,
            appName: appName,
            serviceCount: serviceCount,
            iconBytes: iconBytes,
            appColor: appColor,
            subtitle: subtitle,
            groupState: groupState,
            hasIssue: hasIssue,
            onGroupStateChanged: onGroupStateChanged,
            menuItems: menuItems,
            onMenuSelected: onMenuSelected,
            icon: icon,
            onSelect: onSelect,
            isInSelectionMode: isInSelectionMode,
            isSelected: isSelected,
            isPartiallySelected: isPartiallySelected,
            isRestoredMissing: isRestoredMissing,
          ),
        ),
        if (children.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  reverseDuration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment.topCenter,
                  child: expanded
                      ? ColoredBox(
                          color: bodyBg,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (int i = 0; i < children.length; i++) ...[
                                children[i],
                                if (i < children.length - 1)
                                  Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: 0.5),
                                  ),
                              ],
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AppGroupCardHeaderDelegate extends SliverPersistentHeaderDelegate {
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final String packageName;
  final String appName;
  final int serviceCount;
  final Uint8List? iconBytes;
  final Color? appColor;
  final String subtitle;
  final int? groupState;
  final bool hasIssue;
  final void Function(int)? onGroupStateChanged;
  final List<PopupMenuEntry<String>> menuItems;
  final void Function(String) onMenuSelected;
  final Widget? icon;
  final VoidCallback? onSelect;
  final bool isInSelectionMode;
  final bool isSelected;
  final bool isPartiallySelected;
  final bool isRestoredMissing;

  const _AppGroupCardHeaderDelegate({
    required this.expanded,
    required this.onToggleExpanded,
    required this.packageName,
    required this.appName,
    required this.serviceCount,
    this.iconBytes,
    this.appColor,
    required this.subtitle,
    this.groupState,
    this.hasIssue = false,
    this.onGroupStateChanged,
    required this.menuItems,
    required this.onMenuSelected,
    this.icon,
    this.onSelect,
    this.isInSelectionMode = false,
    this.isSelected = false,
    this.isPartiallySelected = false,
    this.isRestoredMissing = false,
  });

  @override
  double get minExtent => 80;
  @override
  double get maxExtent => 80;

  @override
bool shouldRebuild(_AppGroupCardHeaderDelegate old) =>
    expanded != old.expanded ||
    packageName != old.packageName ||
    appName != old.appName ||
    serviceCount != old.serviceCount ||
    iconBytes != old.iconBytes ||
    appColor != old.appColor ||
    subtitle != old.subtitle ||
    groupState != old.groupState ||
    hasIssue != old.hasIssue ||
    icon != old.icon ||
    isInSelectionMode != old.isInSelectionMode ||
    isSelected != old.isSelected ||
    isPartiallySelected != old.isPartiallySelected ||
    isRestoredMissing != old.isRestoredMissing;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final theme = Theme.of(context);

    final Color? headerFg = appColor == null
        ? null
        : (ThemeData.estimateBrightnessForColor(appColor!) == Brightness.dark
            ? Colors.white
            : Colors.black87);

    final dark = theme.brightness == Brightness.dark;

    final bodyBg = appColor == null
        ? theme.colorScheme.surfaceContainerLow
        : Color.alphaBlend(
            appColor!.withValues(alpha: dark ? 0.22 : 0.10),
            dark ? const Color(0xFF1C1C1C) : Colors.white,
          );

    Color bgColor = appColor ?? theme.colorScheme.surfaceContainerHighest;
    if (isSelected || isPartiallySelected) {
      bgColor = Color.alphaBlend(
          theme.colorScheme.primary.withValues(alpha: 0.15), bgColor);
    }
    final fg = headerFg ?? theme.colorScheme.onSurface;

    final cardRadius = BorderRadius.only(
      topLeft: const Radius.circular(12),
      topRight: const Radius.circular(12),
      bottomLeft: expanded ? Radius.zero : const Radius.circular(12),
      bottomRight: expanded ? Radius.zero : const Radius.circular(12),
    );

    final Widget avatar = icon ??
        (iconBytes != null
            ? CircleAvatar(
                radius: 20,
                backgroundImage: MemoryImage(iconBytes!),
                backgroundColor: Colors.transparent,
              )
            : CircleAvatar(
                radius: 20,
                backgroundColor: appColor ?? theme.colorScheme.primaryContainer,
                child: Text(
                  packageName.isNotEmpty
                      ? packageName.split('.').last[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                      color: headerFg ?? theme.colorScheme.onPrimaryContainer),
                ),
              ));

    final Widget badgedAvatar = Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          key: const ValueKey('service-count-badge'),
          top: -5,
          right: -5,
          child: Semantics(
            label: '$serviceCount monitored services',
            child: Container(
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: bgColor, width: 1.5),
              ),
              child: Text(
                '$serviceCount',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 9,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Material(
          color: bgColor,
          borderRadius: cardRadius,
          elevation: overlapsContent ? 4 : 1,
          shadowColor: Colors.black26,
          child: InkWell(
            borderRadius: cardRadius,
            onTap: isInSelectionMode && onSelect != null
                ? onSelect
                : onToggleExpanded,
            onLongPress: !isInSelectionMode ? onSelect : null,
            child: SizedBox(
              height: 72,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    if (isInSelectionMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: isPartiallySelected
                            ? Icon(Icons.indeterminate_check_box_outlined,
                                color: fg, size: 20)
                            : (isSelected
                                ? Icon(Icons.check_box, color: fg, size: 20)
                                : Icon(Icons.check_box_outline_blank,
                                    color: fg.withValues(alpha: 0.5), size: 20)),
                      ),
                    badgedAvatar,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Tooltip(
                            message: appName,
                            waitDuration: const Duration(milliseconds: 350),
                            child: Text(
                              appName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              softWrap: true,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: fg,
                              ),
                            ),
                          ),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: headerFg?.withValues(alpha: 0.75) ??
                                  theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (isRestoredMissing)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.warning_amber_rounded,
                                      size: 11,
                                      color: theme.colorScheme.error),
                                  const SizedBox(width: 3),
                                  Text(
                                    'App not installed',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontSize: 10,
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (groupState != null && onGroupStateChanged != null)
                      _buildToggle(theme, fg, bodyBg, appColor: appColor),
                    if (menuItems.isNotEmpty)
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert, size: 20, color: fg),
                        padding: EdgeInsets.zero,
                        onSelected: onMenuSelected,
                        itemBuilder: (_) => menuItems,
                        elevation: 4,
                      ),
                    _ExpandChevron(expanded: expanded, color: fg),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToggle(ThemeData theme, Color fg, Color bodyBg, {Color? appColor}) {
    final cs = theme.colorScheme;
    final headerBg = appColor ?? cs.surfaceContainerLow;
    return _GroupToggle(
      value: groupState!,
      hasIssue: hasIssue,
      appColor: appColor,
      bodyBg: bodyBg,
      fg: fg,
      darkHeader: ThemeData.estimateBrightnessForColor(headerBg) == Brightness.dark,
      cs: cs,
      onChanged: onGroupStateChanged!,
    );
  }
}

class _ExpandChevron extends StatefulWidget {
  final bool expanded;
  final Color color;

  const _ExpandChevron({required this.expanded, required this.color});

  @override
  State<_ExpandChevron> createState() => _ExpandChevronState();
}

class _ExpandChevronState extends State<_ExpandChevron>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
    value: widget.expanded ? 1 : 0,
  );

  late final Animation<double> _turns = Tween<double>(begin: 0, end: 0.5)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic));

  @override
  void didUpdateWidget(covariant _ExpandChevron oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _turns,
      child: Icon(Icons.expand_more, color: widget.color),
    );
  }
}

class _GroupToggle extends StatefulWidget {
  final int value;
  final bool hasIssue;
  final Color? appColor;
  final Color bodyBg;
  final Color fg;
  final bool darkHeader;
  final ColorScheme cs;
  final void Function(int) onChanged;

  const _GroupToggle({
    required this.value,
    required this.hasIssue,
    this.appColor,
    required this.bodyBg,
    required this.fg,
    required this.darkHeader,
    required this.cs,
    required this.onChanged,
  });

  @override
  State<_GroupToggle> createState() => _GroupToggleState();
}

class _GroupToggleState extends State<_GroupToggle> {
  int? _dragState;

  static const _totalWidth = 32.0 * 3;
  static const _height = 32.0;
  static const _trackPad = 1.0;
  static const _slotWidth = (_totalWidth - 2 * _trackPad) / 3;

  int get _current => _dragState ?? widget.value;

  double _thumbSize(int state) => _height - (state == 0 ? 12.0 : 8.0 * _trackPad);

  double _thumbLeft(int state) {
    final ts = _thumbSize(state);
    return _trackPad + _slotWidth * state + (_slotWidth - ts) / 2;
  }

  int _slotAt(double localX) {
    final inner = (localX - _trackPad).clamp(0.0, _totalWidth - 2 * _trackPad - 0.001);
    return (inner / _slotWidth).floor().clamp(0, 2);
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.cs;
    final current = _current;
    final dragging = _dragState != null;

    final bool colorful = widget.appColor != null;
    final bool darkMode = cs.brightness == Brightness.dark;
    final Color colorBase = darkMode ? const Color(0xFF1C1C1C) : Colors.white;

    final Color state2Pill = colorful
        ? Color.alphaBlend(widget.appColor!.withValues(alpha: 0.60), colorBase)
        : cs.primary;

    final Color pillColor = switch (current) {
      0 => Colors.transparent,
      1 => widget.hasIssue ? cs.errorContainer : state2Pill,
      _ => state2Pill,
    };
    final Color activeOnPill = colorful
        ? (ThemeData.estimateBrightnessForColor(state2Pill) == Brightness.dark
            ? Colors.white
            : Colors.black87)
        : cs.onPrimary;
    final Color onPill = switch (current) {
      0 => cs.onError,
      1 => widget.hasIssue ? cs.onErrorContainer : activeOnPill,
      _ => activeOnPill,
    };
    final Color trackBg = colorful
        ? (widget.darkHeader
            ? Colors.white.withValues(alpha: 0.15)
            : Colors.black.withValues(alpha: 0.10))
        : cs.surfaceContainerLow;
    final Color borderColor = colorful
        ? widget.bodyBg
        : (widget.darkHeader
            ? Colors.white.withValues(alpha: 0.40)
            : Colors.black.withValues(alpha: current == 0 ? 0.5 : 0.22));
    final Color dimColor = widget.appColor != null
        ? (widget.darkHeader
            ? Colors.white.withValues(alpha: 0.50)
            : Colors.black.withValues(alpha: 0.38))
        : cs.onSurfaceVariant.withValues(alpha: 0.6);

    final icons = [
      current >= 1 ? Icons.check_circle_outline : Icons.block_outlined,
      Icons.visibility,
      Icons.notifications_active,
    ];

    final thumbSize = _thumbSize(current);
    final thumbLeft = _thumbLeft(current);
    final dur = dragging ? Duration.zero : const Duration(milliseconds: 250);

    const stateLabels = ['Disabled', 'Monitoring', 'Monitoring and Notifications'];

    return Semantics(
      label: 'Service monitoring',
      value: stateLabels[current],
      increasedValue: current < 2 ? stateLabels[current + 1] : null,
      decreasedValue: current > 0 ? stateLabels[current - 1] : null,
      onIncrease: current < 2 ? () => widget.onChanged(current + 1) : null,
      onDecrease: current > 0 ? () => widget.onChanged(current - 1) : null,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight && current < 2) {
              widget.onChanged(current + 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft && current > 0) {
              widget.onChanged(current - 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              widget.onChanged((current + 1) % 3);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Tap: determine slot from touch position, commit immediately.
      onTapUp: (d) => widget.onChanged(_slotAt(d.localPosition.dx)),
      // Drag: snap thumb to each slot as finger moves, commit on release.
      onHorizontalDragUpdate: (d) {
        final s = _slotAt(d.localPosition.dx);
        if (s != _dragState) setState(() => _dragState = s);
      },
      onHorizontalDragEnd: (_) {
        final s = _dragState ?? widget.value;
        setState(() => _dragState = null);
        widget.onChanged(s);
      },
      onHorizontalDragCancel: () => setState(() => _dragState = null),
      child: SizedBox(
        width: _totalWidth,
        height: _height,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: trackBg,
                  borderRadius: BorderRadius.circular(_height / 2),
                  border: Border.all(color: borderColor, width: 1.5),
                ),
              ),
            ),
            Positioned(
              left: _trackPad,
              top: _trackPad,
              bottom: _trackPad,
              child: AnimatedContainer(
                duration: dur,
                curve: Curves.easeInOut,
                width: _slotWidth * (current + 1),
                decoration: BoxDecoration(
                  color: pillColor,
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: dur,
              curve: Curves.easeInOut,
              left: thumbLeft,
              top: _height / 2 - thumbSize / 2,
              child: AnimatedContainer(
                duration: dur,
                width: thumbSize,
                height: thumbSize,
                decoration: BoxDecoration(
                  color: current == 0
                      ? (colorful
                          ? widget.bodyBg
                          : (darkMode ? const Color(0xFF4E5057) : Colors.black54))
                      : (colorful
                          ? widget.appColor!
                          : (darkMode ? cs.onPrimary : Colors.white)),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: current > 0
                          ? Colors.black.withValues(alpha: 0.22)
                          : Colors.transparent,
                      blurRadius: current == 0 ? 0 : 4,
                      spreadRadius: current == 0 ? 0 : 1,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: _trackPad,
              top: 0,
              right: _trackPad,
              bottom: 0,
              child: Row(
                children: List.generate(3, (i) => SizedBox(
                  width: _slotWidth,
                  child: Icon(
                    icons[i],
                    size: 15,
                    color: (current == 0 && i == 0)
                        ? (cs.brightness == Brightness.dark
                            ? const Color(0xFF80828A)
                            : Colors.black45)
                        : (i < current || i == 0
                            ? onPill
                            : (i == current
                                ? (colorful && current >= 1
                                    ? (ThemeData.estimateBrightnessForColor(widget.appColor!) == Brightness.dark
                                        ? Colors.white
                                        : Colors.black87)
                                    : pillColor)
                                : dimColor)),
                  ),
                )),
              ),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}
