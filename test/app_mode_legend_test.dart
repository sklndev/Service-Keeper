import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_keeper/widgets/app_mode_legend.dart';

void main() {
  testWidgets('mode pills select the app group state', (tester) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppModeLegend(
            value: 1,
            onChanged: (value) => selected = value,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('app-mode-0')));
    expect(selected, 0);

    await tester.tap(find.byKey(const ValueKey('app-mode-2')));
    expect(selected, 2);
  });
}