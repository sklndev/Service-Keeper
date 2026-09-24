import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_keeper/widgets/app_group_card.dart';

void main() {
  testWidgets('shows service count on the top-right of the app icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              AppGroupCard(
                expanded: false,
                onToggleExpanded: () {},
                packageName: 'com.example.app',
                appName: 'Example App',
                serviceCount: 3,
                subtitle: 'App restart on',
                menuItems: const [],
                onMenuSelected: (_) {},
                children: const [],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Example App'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('App restart on'), findsOneWidget);
    expect(find.textContaining('services monitored'), findsNothing);

    final badge = tester.widget<Positioned>(
      find.byKey(const ValueKey('service-count-badge')),
    );
    expect(badge.top, -5);
    expect(badge.right, -5);
  });
}