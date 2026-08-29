import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/library_screen.dart';
import 'services/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Load before the first frame so the fretboard is never briefly uncalibrated.
  await AppSettings.instance.load();
  runApp(const BassTrainerApp());
}

class BassTrainerApp extends StatelessWidget {
  const BassTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFB300),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Bass Trainer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        sliderTheme: const SliderThemeData(
          trackHeight: 3,
          overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
        ),
      ),
      home: const LibraryScreen(),
    );
  }
}
