import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_keeper/main.dart';

void main() {
  testWidgets('App smoke test', (tester) async {
    await tester.pumpWidget(const ServiceKeeperApp());
    expect(find.text('Service Keeper'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 480));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 280));
    await tester.pump(const Duration(milliseconds: 1050));
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
