import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'app_settings_notifier.dart';
import 'screens/splash_screen.dart';
import 'services/app_info_service.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName == 'serviceCheck' && inputData != null) {
      final pkg = inputData['packageName'] as String?;
      final cls = inputData['serviceClass'] as String?;
      final label = inputData['displayLabel'] as String? ?? '';
      final selfChain = inputData['selfChain'] as bool? ?? false;
      final intervalMinutes = inputData['intervalMinutes'] as int? ?? 15;

      if (pkg != null && cls != null) {
        await _checkAndRestart(pkg, cls, label);
      }

      // Re-schedule self for sub-15-min intervals
      if (selfChain && pkg != null && cls != null) {
        final tag = '${pkg}_${cls.replaceAll('.', '_')}';
        Workmanager().registerOneOffTask(
          '${tag}_once',
          'serviceCheck',
          tag: tag,
          initialDelay: Duration(minutes: intervalMinutes),
          inputData: inputData,
        );
      }
    }
    return Future.value(true);
  });
}

Future<void> _checkAndRestart(
    String packageName, String serviceClass, String label) async {
  // Native shell execution is not directly available in the Dart isolate;
  // the MonitorWorker.kt handles the actual Shizuku calls from WorkManager.
  // This Dart callback is a placeholder for any pure-Dart work.
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  materialYouNotifier.value = prefs.getBool('use_material_you') ?? false;
  colorfulCardsNotifier.value = prefs.getBool('use_app_colors') ?? false;

  if (materialYouNotifier.value) {
    wallpaperSeedNotifier.value = await AppInfoService.getWallpaperSeedColor();
  }

  await Workmanager().initialize(
    callbackDispatcher,
  );

  runApp(const ServiceKeeperApp());
}

// Midpoint of the icon's cyan-teal gradient
const _brandSeed = Color(0xFF00C4A8);

const _subThemes = FlexSubThemesData(
  interactionEffects: true,
  defaultRadius: 10,
  elevatedButtonRadius: 10,
  outlinedButtonRadius: 10,
  textButtonRadius: 10,
  filledButtonRadius: 10,
  cardRadius: 10,
  inputDecoratorRadius: 8,
  inputDecoratorUnfocusedHasBorder: true,
  dialogRadius: 16,
  bottomSheetRadius: 16,
  chipRadius: 8,
  switchSchemeColor: SchemeColor.primary,
  checkboxSchemeColor: SchemeColor.primary,
  radioSchemeColor: SchemeColor.primary,
  navigationBarSelectedLabelSchemeColor: SchemeColor.primary,
  navigationBarSelectedIconSchemeColor: SchemeColor.primary,
  navigationBarIndicatorSchemeColor: SchemeColor.primaryContainer,
);

ThemeData _buildLight(ColorScheme? dynamic, Color? seed) {
  final scheme = dynamic ??
      ColorScheme.fromSeed(seedColor: seed ?? _brandSeed, brightness: Brightness.light);
  return FlexColorScheme.light(
    colorScheme: scheme,
    surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
    blendLevel: 5,
    subThemesData: _subThemes,
  ).toTheme.copyWith(
    textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Inter'),
  );
}

ThemeData _buildDark(ColorScheme? dynamic, Color? seed) {
  final scheme = dynamic ??
      ColorScheme.fromSeed(seedColor: seed ?? _brandSeed, brightness: Brightness.dark);
  return FlexColorScheme.dark(
    colorScheme: scheme,
    surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
    blendLevel: 10,
    subThemesData: _subThemes,
  ).toTheme.copyWith(
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
  );
}

class ServiceKeeperApp extends StatelessWidget {
  const ServiceKeeperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return ListenableBuilder(
          listenable: Listenable.merge([materialYouNotifier, wallpaperSeedNotifier]),
          builder: (context, _) {
            final useMY = materialYouNotifier.value;
            final seed = wallpaperSeedNotifier.value;

            return MaterialApp(
              title: 'Service Keeper',
              debugShowCheckedModeBanner: false,
              theme: _buildLight(useMY ? lightDynamic : null, useMY ? seed : null),
              darkTheme: _buildDark(useMY ? darkDynamic : null, useMY ? seed : null),
              home: const SplashScreen(),
            );
          },
        );
      },
    );
  }
}
