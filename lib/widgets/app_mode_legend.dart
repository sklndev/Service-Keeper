import 'package:flutter/material.dart';

class AppModeLegend extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const AppModeLegend({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget item(int itemValue, String label, Color activeBg, Color activeFg) {
      final selected = value == itemValue;
      final radius = BorderRadius.circular(999);
      return Semantics(
        button: true,
        selected: selected,
        label: 'Set app mode to $label',
        child: Material(
          color: selected ? activeBg : cs.surfaceContainerHigh,
          borderRadius: radius,
          child: InkWell(
            key: ValueKey('app-mode-$itemValue'),
            borderRadius: radius,
            onTap: selected ? null : () => onChanged(itemValue),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: selected ? activeBg : cs.outlineVariant,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: selected ? activeFg : cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          item(0, 'Disabled', cs.errorContainer, cs.onErrorContainer),
          const SizedBox(width: 6),
          item(1, 'Monitor', cs.tertiaryContainer, cs.onTertiaryContainer),
          const SizedBox(width: 6),
          item(2, 'Notify', cs.primaryContainer, cs.onPrimaryContainer),
          const Spacer(),
          Text(
            'Mode',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}