import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/library_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
