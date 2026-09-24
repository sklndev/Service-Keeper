import 'package:flutter_test/flutter_test.dart';
import 'package:service_keeper/models/monitored_service.dart';

void main() {
  group('MonitoredService.serviceDisplayName', () {
    test('uses a descriptive stored label', () {
      const service = MonitoredService(
        packageName: 'com.example.app',
        serviceClass: 'com.example.app.SyncService',
        displayLabel: 'Background sync',
        appName: 'Example',
      );

      expect(service.serviceDisplayName, 'Background sync');
    });

    test('uses the class name when the label is the app name', () {
      const service = MonitoredService(
        packageName: 'com.life360.android.safetymapd',
        serviceClass: 'com.life360.android.safetymapd.services.LocationService',
        displayLabel: 'Life360',
        appName: 'Life360',
      );

      expect(service.serviceDisplayName, 'LocationService');
    });

    test('uses the class name when the label is empty', () {
      const service = MonitoredService(
        packageName: 'com.example.app',
        serviceClass: 'com.example.app.Service1',
        displayLabel: '',
      );

      expect(service.serviceDisplayName, 'Service1');
    });
  });
}
