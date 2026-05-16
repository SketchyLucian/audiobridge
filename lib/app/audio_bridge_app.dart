import 'package:flutter/material.dart';

import '../features/audio_relay/presentation/audio_relay_screen.dart';
import 'app_theme.dart';

class AudioBridgeApp extends StatelessWidget {
  const AudioBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AudioBridge',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const AudioRelayScreen(),
    );
  }
}
