import 'dart:io';

import 'package:audiorelay_clone/app/audio_bridge_app.dart';
import 'package:audiorelay_clone/features/audio_relay/application/audio_relay_controller.dart';
import 'package:audiorelay_clone/features/audio_relay/data/native_audio_engine.dart';
import 'package:audiorelay_clone/features/audio_relay/domain/audio_relay_models.dart';
import 'package:audiorelay_clone/features/audio_relay/presentation/audio_relay_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the audio relay dashboard', (tester) async {
    await tester.pumpWidget(const AudioBridgeApp());
    await tester.pump();

    expect(find.text('AudioBridge'), findsOneWidget);
    expect(find.text('Sender'), findsWidgets);
    expect(find.text('Receiver'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsWidgets);
    expect(
      find.text('USB tether'),
      Platform.isLinux ? findsNothing : findsOneWidget,
    );
    expect(
      find.text('Native USB'),
      Platform.isLinux ? findsNothing : findsOneWidget,
    );
    expect(find.text('Soundboard'), findsOneWidget);
    expect(find.text('Audio settings'), findsOneWidget);
    expect(find.text('Simple'), findsNothing);
    expect(find.text('Advanced'), findsNothing);
    expect(find.text('Gaming'), findsOneWidget);
    expect(find.text('Balanced'), findsWidgets);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Format and bandwidth'), findsOneWidget);
    expect(find.byKey(const ValueKey('mono-channel-option')), findsOneWidget);
    expect(find.byKey(const ValueKey('stereo-channel-option')), findsOneWidget);
    expect(find.text('Latency and stability'), findsOneWidget);
    expect(find.text('Bitrate'), findsWidgets);
    expect(find.text('Sender buffer'), findsOneWidget);
    expect(find.text('Receiver buffer'), findsWidgets);
    expect(find.text('Receiver adaptive buffer'), findsNothing);
    expect(find.byIcon(Icons.tune_rounded), findsWidgets);
  });

  testWidgets('opens the soundboard in its own tab', (tester) async {
    await tester.pumpWidget(const AudioBridgeApp());
    await tester.pump();

    expect(find.text('Add sound'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('soundboard-tab')));
    await tester.pumpAndSettle();

    expect(find.text('Add sound'), findsOneWidget);
    expect(find.text('Audio settings'), findsNothing);
  });

  testWidgets('changes the stream channel format to mono', (tester) async {
    await tester.pumpWidget(const AudioBridgeApp());
    await tester.pump();

    expect(
      tester
          .widget<SegmentedButton<int>>(
            find.byKey(const ValueKey('channel-picker')),
          )
          .selected,
      {2},
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('mono-channel-option')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mono-channel-option')));
    await tester.pump();

    expect(
      tester
          .widget<SegmentedButton<int>>(
            find.byKey(const ValueKey('channel-picker')),
          )
          .selected,
      {1},
    );
  });

  testWidgets('tapping an available source connects immediately', (
    tester,
  ) async {
    final engine = _WidgetTestAudioEngine();
    final device = RelayDevice(
      id: 'source-1',
      name: 'Office PC',
      host: '192.168.1.25',
      port: 39120,
      transport: RelayTransport.wifi,
      platform: DevicePlatform.windows,
      profile: AudioPreset.balanced.profile,
      lastSeen: DateTime(2026),
    );
    final controller = AudioRelayController(engine: engine)
      ..role = RelayRole.receiver
      ..activity = RelayActivity.scanning
      ..devices = [device];

    await tester.pumpWidget(
      MaterialApp(home: AudioRelayScreen(controller: controller)),
    );
    final sourceRow = find.byKey(const ValueKey('available-source-source-1'));
    await tester.ensureVisible(sourceRow);
    await tester.pumpAndSettle();

    await tester.tap(sourceRow);
    await tester.pump();

    expect(engine.connectedDevices, [device]);
    expect(engine.startStreamCalls, 1);
    expect(controller.selectedDevice, same(device));
    expect(controller.activity, RelayActivity.streaming);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

class _WidgetTestAudioEngine implements AudioRelayEngine {
  final List<RelayDevice> connectedDevices = [];
  int startStreamCalls = 0;

  @override
  Future<void> connectToSender(RelayDevice device, AudioProfile profile) async {
    connectedDevices.add(device);
  }

  @override
  Future<void> configureVirtualMicPassthrough({
    required bool enabled,
    String? outputDeviceId,
  }) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<PlatformAudioCapabilities> getCapabilities() async {
    return PlatformAudioCapabilities.fallback();
  }

  @override
  Future<AudioRelayMetrics> getMetrics() async => AudioRelayMetrics.empty;

  @override
  Future<void> launchVirtualMicSetup() async {}

  @override
  Future<void> playSoundEffect({
    required String path,
    required double volume,
    required SoundboardPlaybackTarget target,
    String? outputDeviceId,
  }) async {}

  @override
  Future<void> prepareReceiver(AudioProfile profile) async {}

  @override
  Future<void> prepareSender(
    AudioProfile profile, {
    String? networkBindAddress,
    RelayTransport transport = RelayTransport.wifi,
    String? captureOutputDeviceId,
  }) async {}

  @override
  Future<void> prepareUsbReceiver(AudioProfile profile) async {}

  @override
  Future<void> prepareUsbSender(
    AudioProfile profile, {
    String? captureOutputDeviceId,
  }) async {}

  @override
  Future<void> setMuted(bool value) async {}

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> startStream(
    AudioProfile profile, {
    String? captureOutputDeviceId,
  }) async {
    startStreamCalls += 1;
  }

  @override
  Future<void> stopSoundEffects() async {}

  @override
  Future<void> stopStream() async {}
}
