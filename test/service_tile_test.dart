import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_keeper/models/monitored_service.dart';
import 'package:service_keeper/widgets/service_tile.dart';

void main() {
  testWidgets('shows a pulsing running badge before the service name', (tester) async {
    var notificationToggles = 0;
    const service = MonitoredService(
      packageName: 'com.example.app',
      serviceClass: 'com.example.app.SyncService',
      displayLabel: 'SyncService',
      wasRunning: true,
      appRestartEnabled: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServiceTile(
            service: service,
            now: DateTime(2026),
            showLeading: false,
            globalIntervalEnabled: false,
            onToggleNotifications: () => notificationToggles++,
          ),
        ),
      ),
    );

    final badge = find.byKey(const ValueKey('service-status-badge'));
    final name = find.text('SyncService');

    expect(badge, findsOneWidget);
    final pulseFinder = find.byKey(const ValueKey('running-status-pulse'));
    final ringFinder =
        find.byKey(const ValueKey('running-status-ping-ring'));
    final initialOpacity = tester.widget<Opacity>(ringFinder).opacity;
    final initialScale = tester
        .widget<Transform>(find.descendant(
          of: ringFinder,
          matching: find.byType(Transform),
        ))
        .transform
        .getMaxScaleOnAxis();
    await tester.pump(const Duration(milliseconds: 225));
    final pulsedOpacity = tester.widget<Opacity>(ringFinder).opacity;
    final pulsedScale = tester
        .widget<Transform>(find.descendant(
          of: ringFinder,
          matching: find.byType(Transform),
        ))
        .transform
        .getMaxScaleOnAxis();

    expect(pulseFinder, findsOneWidget);
    expect(find.byKey(const ValueKey('running-status-solid-dot')), findsOneWidget);
    expect(pulsedScale, greaterThan(initialScale));
    expect(pulsedOpacity, lessThan(initialOpacity));
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.open_in_browser), findsNothing);
    expect(find.text('Running'), findsNothing);
    expect(tester.getTopLeft(badge).dx, lessThan(tester.getTopLeft(name).dx));

    final notificationToggle =
      find.byKey(const ValueKey('service-notification-toggle'));
    expect(notificationToggle, findsOneWidget);
    expect(tester.getTopLeft(notificationToggle).dx,
      greaterThan(tester.getTopLeft(name).dx));
    await tester.tap(notificationToggle);
    expect(notificationToggles, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rotates the status icon while restarting', (tester) async {
    const service = MonitoredService(
      packageName: 'com.example.app',
      serviceClass: 'com.example.app.SyncService',
      displayLabel: 'SyncService',
      wasRunning: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServiceTile(
            service: service,
            now: DateTime(2026),
            showLeading: false,
            globalIntervalEnabled: false,
            isRestarting: true,
          ),
        ),
      ),
    );

    final rotationFinder =
        find.byKey(const ValueKey('restart-status-rotation'));
    final initialTurns =
        tester.widget<RotationTransition>(rotationFinder).turns.value;

    await tester.pump(const Duration(milliseconds: 225));

    final rotatedTurns =
        tester.widget<RotationTransition>(rotationFinder).turns.value;
    expect(rotatedTurns, isNot(initialTurns));
    expect(find.byIcon(Icons.sync_rounded), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}