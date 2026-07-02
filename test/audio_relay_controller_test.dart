import 'dart:async';
import 'dart:io';

import 'package:audiorelay_clone/features/audio_relay/application/audio_relay_controller.dart';
import 'package:audiorelay_clone/features/audio_relay/data/audio_profile_store.dart';
import 'package:audiorelay_clone/features/audio_relay/data/audio_relay_preferences_store.dart';
import 'package:audiorelay_clone/features/audio_relay/data/discovery_service.dart';
import 'package:audiorelay_clone/features/audio_relay/data/native_audio_engine.dart';
import 'package:audiorelay_clone/features/audio_relay/data/update_platform.dart';
import 'package:audiorelay_clone/features/audio_relay/data/update_service.dart';
import 'package:audiorelay_clone/features/audio_relay/domain/audio_relay_models.dart';
import 'package:audiorelay_clone/features/audio_relay/domain/update_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts with the balanced preset profile', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    expect(controller.selectedPreset, AudioPreset.balanced);
    expect(
      controller.profile.hasSameSettings(AudioPreset.balanced.profile),
      true,
    );

    controller.dispose();
  });

  test('manual setting changes keep the selected mode', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.updateSampleRate(96000);

    expect(controller.selectedPreset, AudioPreset.balanced);
    expect(controller.profile.mode, AudioPreset.balanced);
    expect(controller.presetLabel, 'Balanced mode');

    controller.dispose();
  });

  test('music preset prioritizes large receiver buffering', () {
    final music = AudioPreset.music.profile;

    expect(AudioProfile.maxBufferMs, 500);
    expect(music.captureBufferMs, 160);
    expect(music.playbackBufferMs, 320);
    expect(music.packetTimeMs, 12);
    expect(music.receiverAdaptiveBuffer, true);
  });

  test('gaming preset defaults to auto codec for low latency', () {
    final gaming = AudioPreset.gaming.profile;

    expect(gaming.codec, AudioCodec.auto);
    expect(AudioProfile.usbLowLatency.codec, AudioCodec.auto);
    expect(AudioProfile.usbTetheringLowLatency.codec, AudioCodec.auto);
  });

  test('all presets default to stereo', () {
    for (final preset in AudioPreset.values) {
      expect(preset.profile.channels, 2);
    }
  });

  test('audio profiles parse and clamp mono or stereo channels', () {
    final monoProfile = AudioProfile.fromMap({
      'mode': 'gaming',
      'sampleRate': 48000,
      'channels': 1,
    });
    final excessiveProfile = AudioProfile.fromMap({'channels': 8});

    expect(monoProfile.channels, 1);
    expect(monoProfile.toMap()['channels'], 1);
    expect(excessiveProfile.channels, 2);
  });

  test('channel setting changes between mono and stereo', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.updateChannels(1);

    expect(controller.profile.channels, 1);
    expect(controller.channelModeLabel, 'Mono');

    controller.dispose();
  });

  test('mono PCM uses half the stereo bandwidth', () {
    final stereo = AudioPreset.balanced.profile;
    final mono = stereo.copyWith(channels: 1);

    expect(mono.effectiveBitrateKbps, stereo.effectiveBitrateKbps ~/ 2);
  });

  test('manual values auto-match a known preset again', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.updateSampleRate(96000);
    expect(controller.selectedPreset, AudioPreset.balanced);

    final balanced = AudioPreset.balanced.profile;
    controller.updateSampleRate(balanced.sampleRate);
    controller.updateChannels(balanced.channels);
    controller.updateCaptureBuffer(balanced.captureBufferMs.toDouble());
    controller.updatePlaybackBuffer(balanced.playbackBufferMs.toDouble());
    controller.updatePacketTime(balanced.packetTimeMs.toDouble());

    expect(controller.selectedPreset, AudioPreset.balanced);
    expect(controller.profile.mode, AudioPreset.balanced);
    expect(controller.profile.hasSameSettings(balanced), true);

    controller.dispose();
  });

  test('receiver adaptive buffer toggle is independent of preset', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender;

    controller.updateReceiverAdaptiveBuffer(false);

    expect(controller.selectedPreset, AudioPreset.balanced);
    expect(controller.profile.receiverAdaptiveBuffer, false);
    expect(
      controller.profile.hasSameStreamSettings(AudioPreset.balanced.profile),
      true,
    );
    expect(
      controller.profile.hasSameSettings(AudioPreset.balanced.profile),
      false,
    );
    expect(controller.receiverAdaptiveBufferLabel, 'Fixed');

    controller.dispose();
  });

  test('custom mode saves current settings and restores them', () {
    final store = _FakeAudioProfileStore();
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(),
      discoveryService: _FakeDiscoveryService(),
      profileStore: store,
      checkForUpdatesOnInitialize: false,
    );

    controller.updatePreset(AudioPreset.gaming);
    controller.updateChannels(1);
    controller.updatePlaybackBuffer(22);
    controller.saveCustomPreset();
    controller.updateAdaptiveBufferCap(54);

    expect(controller.selectedPreset, AudioPreset.custom);
    expect(controller.profile.mode, AudioPreset.custom);
    expect(controller.profile.playbackBufferMs, 22);
    expect(controller.profile.channels, 1);
    expect(controller.profile.adaptiveBufferCapMs, 54);
    expect(store.savedProfile?.mode, AudioPreset.custom);
    expect(store.savedProfile?.playbackBufferMs, 22);
    expect(store.savedProfile?.channels, 1);

    controller.updatePreset(AudioPreset.music);
    controller.updatePreset(AudioPreset.custom);

    expect(controller.profile.mode, AudioPreset.custom);
    expect(controller.profile.playbackBufferMs, 22);
    expect(controller.profile.channels, 1);
    expect(controller.profile.adaptiveBufferCapMs, 54);

    controller.dispose();
  });

  test(
    'custom profile save failures do not escape controller updates',
    () async {
      final store = _FakeAudioProfileStore(
        saveError: StateError('write failed'),
      );
      final controller = AudioRelayController(
        engine: _FakeAudioRelayEngine(),
        discoveryService: _FakeDiscoveryService(),
        profileStore: store,
      );

      controller.saveCustomPreset();
      await Future<void>.delayed(Duration.zero);

      expect(controller.selectedPreset, AudioPreset.custom);
      expect(controller.profile.mode, AudioPreset.custom);

      controller.dispose();
    },
  );

  test('initialize loads saved custom mode profile', () async {
    final store = _FakeAudioProfileStore(
      savedProfile: AudioPreset.custom.profile.copyWith(
        playbackBufferMs: 72,
        adaptiveBufferCapMs: 144,
      ),
    );
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(),
      discoveryService: _FakeDiscoveryService(),
      profileStore: store,
      preferencesStore: _FakeAudioRelayPreferencesStore(),
    );

    await controller.initialize();
    controller.updatePreset(AudioPreset.custom);

    expect(controller.profile.mode, AudioPreset.custom);
    expect(controller.profile.playbackBufferMs, 72);
    expect(controller.profile.adaptiveBufferCapMs, 144);

    controller.dispose();
  });

  test('initialize restores durable app preferences', () async {
    const firstSound = r'C:\sounds\first.wav';
    const secondSound = r'C:\sounds\second.wav';
    final preferencesStore = _FakeAudioRelayPreferencesStore(
      savedPreferences: AudioRelayPreferences(
        role: RelayRole.sender,
        transport: RelayTransport.usbTethering,
        profile: AudioProfile(
          mode: AudioPreset.custom,
          codec: AudioCodec.pcm,
          sampleRate: 48000,
          bitrateKbps: 768,
          latencyMs: 24,
          captureBufferMs: 12,
          playbackBufferMs: 24,
          packetTimeMs: 2,
          channels: 1,
        ),
        receiverOutputBackend: OutputAudioBackend.auto,
        volume: 0.41,
        muted: true,
        soundboardPaths: [firstSound, secondSound],
        selectedSoundboardPath: secondSound,
        soundboardTarget: SoundboardPlaybackTarget.stream,
        selectedSoundboardOutputDeviceId: 'route-1',
        soundboardVolume: 0.36,
      ),
    );
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(capabilities: _soundboardCapabilities),
      discoveryService: _FakeDiscoveryService(),
      profileStore: _FakeAudioProfileStore(),
      preferencesStore: preferencesStore,
      appVersionProvider: () async => '1.1.0',
      checkForUpdatesOnInitialize: false,
      preferencesSaveDelay: const Duration(days: 1),
    );

    await controller.initialize();

    expect(controller.role, RelayRole.sender);
    expect(controller.transport, RelayTransport.usbTethering);
    expect(controller.profile.mode, AudioPreset.custom);
    expect(controller.profile.channels, 1);
    expect(controller.volume, 0.41);
    expect(controller.muted, true);
    expect(controller.soundboardItems.map((item) => item.path), [
      firstSound,
      secondSound,
    ]);
    expect(controller.selectedSoundboardItem?.path, secondSound);
    expect(controller.soundboardTarget, SoundboardPlaybackTarget.stream);
    expect(controller.selectedSoundboardOutputDeviceId, 'route-1');
    expect(controller.soundboardVolume, 0.36);

    controller.dispose();
  });

  test('flush persists the latest user-controlled settings', () async {
    const soundPath = r'C:\sounds\airhorn.wav';
    final preferencesStore = _FakeAudioRelayPreferencesStore();
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(capabilities: _soundboardCapabilities),
      discoveryService: _FakeDiscoveryService(),
      profileStore: _FakeAudioProfileStore(),
      preferencesStore: preferencesStore,
      appVersionProvider: () async => '1.1.0',
      checkForUpdatesOnInitialize: false,
      preferencesSaveDelay: const Duration(days: 1),
    );
    await controller.initialize();
    preferencesStore.savedPreferences = null;

    controller.updateChannels(1);
    await controller.updateVolume(0.52);
    await controller.updateMuted(true);
    controller.addSoundboardFiles([soundPath]);
    controller.updateSoundboardTarget(SoundboardPlaybackTarget.stream);
    controller.updateSoundboardVolume(0.28);
    await controller.flushPreferences();

    final saved = preferencesStore.savedPreferences;
    expect(saved?.profile.channels, 1);
    expect(saved?.volume, 0.52);
    expect(saved?.muted, true);
    expect(saved?.soundboardPaths, [soundPath]);
    expect(saved?.selectedSoundboardPath, soundPath);
    expect(saved?.soundboardTarget, SoundboardPlaybackTarget.stream);
    expect(saved?.soundboardVolume, 0.28);

    controller.dispose();
  });

  test('sender settings remain editable while streaming', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..activity = RelayActivity.streaming;

    expect(controller.canEditAudioSettings, true);

    controller.dispose();
  });

  test('audio mode remains editable while hosting and streaming', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..activity = RelayActivity.advertising;

    expect(controller.canEditAudioMode, true);
    controller.updatePreset(AudioPreset.gaming);

    expect(controller.selectedPreset, AudioPreset.gaming);
    expect(controller.profile.mode, AudioPreset.gaming);

    controller.activity = RelayActivity.streaming;
    expect(controller.canEditAudioMode, true);
    controller.updatePreset(AudioPreset.music);

    expect(controller.selectedPreset, AudioPreset.music);
    expect(controller.profile.mode, AudioPreset.music);

    controller.dispose();
  });

  test('profile changes are applied to the active sender stream', () async {
    final engine = _FakeAudioRelayEngine();
    final discoveryService = _FakeDiscoveryService();
    final controller = AudioRelayController(
      engine: engine,
      discoveryService: discoveryService,
      profileApplyDelay: Duration.zero,
    )..role = RelayRole.sender;

    await controller.startSenderStream();
    engine.calls.clear();
    engine.profiles.clear();
    discoveryService.advertisedProfiles.clear();

    controller.updatePacketTime(5);
    await Future<void>.delayed(Duration.zero);

    expect(engine.calls, ['prepareSender']);
    expect(engine.profiles.single.packetTimeMs, 5);
    expect(discoveryService.advertisedProfiles.single.packetTimeMs, 5);

    controller.dispose();
  });

  test('restart-required sender changes are held while streaming', () async {
    final engine = _FakeAudioRelayEngine();
    final discoveryService = _FakeDiscoveryService();
    final controller = AudioRelayController(
      engine: engine,
      discoveryService: discoveryService,
      profileApplyDelay: Duration.zero,
    )..role = RelayRole.sender;

    await controller.startSenderStream();
    final streamingProfile = controller.profile;
    engine.calls.clear();
    engine.profiles.clear();
    discoveryService.advertisedProfiles.clear();

    controller.updateSampleRate(96000);
    controller.updateCaptureBuffer(96);
    controller.updateChannels(1);
    await Future<void>.delayed(Duration.zero);

    expect(controller.profile.sampleRate, streamingProfile.sampleRate);
    expect(
      controller.profile.captureBufferMs,
      streamingProfile.captureBufferMs,
    );
    expect(controller.profile.channels, streamingProfile.channels);
    expect(engine.calls, isEmpty);
    expect(discoveryService.advertisedProfiles, isEmpty);

    controller.dispose();
  });

  test(
    'receiver adaptive buffer changes are applied to active sender',
    () async {
      final engine = _FakeAudioRelayEngine();
      final discoveryService = _FakeDiscoveryService();
      final controller = AudioRelayController(
        engine: engine,
        discoveryService: discoveryService,
        profileApplyDelay: Duration.zero,
      )..role = RelayRole.sender;

      await controller.startSenderStream();
      engine.calls.clear();
      engine.profiles.clear();
      discoveryService.advertisedProfiles.clear();

      controller.updateReceiverAdaptiveBuffer(false);
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.receiverAdaptiveBuffer, false);
      expect(
        discoveryService.advertisedProfiles.single.receiverAdaptiveBuffer,
        false,
      );

      controller.dispose();
    },
  );

  test('latency label prefers end-to-end audio latency', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.activity = RelayActivity.streaming;
    controller.metrics = const AudioRelayMetrics(
      audioLatencyMs: 42.4,
      outputLatencyMs: 18.2,
    );

    expect(controller.latencyMetricLabel, 'Audio latency');
    expect(controller.liveLatencyLabel, '42 ms');

    controller.dispose();
  });

  test('latency label falls back to playback buffer latency', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.activity = RelayActivity.streaming;
    controller.metrics = const AudioRelayMetrics(outputLatencyMs: 18.2);

    expect(controller.latencyMetricLabel, 'Playback buffer');
    expect(controller.liveLatencyLabel, '18 ms');

    controller.dispose();
  });

  test('latency display is floored by active receiver buffering', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.activity = RelayActivity.streaming;
    controller.metrics = const AudioRelayMetrics(
      audioLatencyMs: 25,
      networkLatencyMs: 4,
      adaptivePlaybackBufferMs: 140,
    );

    expect(controller.latencyMetricLabel, 'Audio latency');
    expect(controller.liveLatencyLabel, '144 ms');
    expect(controller.bufferingLabel, '140 ms active');

    controller.dispose();
  });

  test('playback latency display is floored by active receiver buffering', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.activity = RelayActivity.streaming;
    controller.metrics = const AudioRelayMetrics(
      outputLatencyMs: 18.2,
      adaptivePlaybackBufferMs: 140,
    );

    expect(controller.latencyMetricLabel, 'Playback buffer');
    expect(controller.liveLatencyLabel, '140 ms');

    controller.dispose();
  });

  test(
    'streaming latency uses requested playback buffer before metrics arrive',
    () {
      final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

      controller.updatePreset(AudioPreset.gaming);
      controller.activity = RelayActivity.streaming;

      expect(controller.latencyMetricLabel, 'Playback buffer');
      expect(controller.liveLatencyLabel, '18 ms');
      expect(controller.activePlaybackBufferLabel, 'Requested 18 ms');
      expect(controller.playbackQueueFillLabel, '0%');
      expect(controller.adaptiveBufferCapLabel, '120 ms');
      expect(controller.receiverBufferValueLabel, '18 ms min');
      expect(controller.receiverBufferDetailLabel, '864 frames minimum');
      expect(
        controller.receiverBufferDescription,
        contains('minimum receiver delay'),
      );

      controller.updateReceiverAdaptiveBuffer(false);
      expect(controller.receiverBufferValueLabel, '18 ms');
      expect(controller.receiverBufferDetailLabel, '864 frames fixed');
      expect(controller.receiverBufferDescription, contains('fixed'));

      controller.dispose();
    },
  );

  test('preset adaptive caps stay mode appropriate', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine());

    controller.updatePreset(AudioPreset.gaming);
    expect(controller.adaptiveBufferCapLabel, '120 ms');

    controller.updatePreset(AudioPreset.balanced);
    expect(controller.adaptiveBufferCapLabel, '240 ms');

    controller.updatePreset(AudioPreset.music);
    expect(controller.adaptiveBufferCapLabel, '500 ms');

    controller.dispose();
  });

  test('metrics parse audio and network latency fields', () {
    final metrics = AudioRelayMetrics.fromMap({
      'audioLatencyMs': 51,
      'outputLatencyMs': '17.5',
      'networkLatencyMs': 3.25,
      'signalLevel': '0.42',
      'queuedFrames': '840',
      'targetBufferFrames': 288,
      'adaptivePlaybackBufferMs': 6,
      'adaptiveMaxPlaybackBufferMs': 48,
      'adaptiveLimitReached': '1',
      'adaptiveUnderrunsInWindow': 5,
      'adaptiveUnderrunsInBurst': '4',
      'adaptiveLowQueueSamples': 3,
      'playbackQueueFillPercent': 72,
      'peerConnected': 'true',
    });

    expect(metrics.audioLatencyMs, 51);
    expect(metrics.outputLatencyMs, 17.5);
    expect(metrics.networkLatencyMs, 3.25);
    expect(metrics.signalLevel, 0.42);
    expect(metrics.queuedFrames, 840);
    expect(metrics.targetBufferFrames, 288);
    expect(metrics.adaptivePlaybackBufferMs, 6);
    expect(metrics.adaptiveMaxPlaybackBufferMs, 48);
    expect(metrics.adaptiveLimitReached, true);
    expect(metrics.adaptiveUnderrunsInWindow, 5);
    expect(metrics.adaptiveUnderrunsInBurst, 4);
    expect(metrics.adaptiveLowQueueSamples, 3);
    expect(metrics.playbackQueueFillPercent, 72);
    expect(metrics.peerConnected, true);
    expect(metrics.effectiveLatencyMs, 51);
  });

  test('signal level follows native metrics', () async {
    final engine = _FakeAudioRelayEngine()
      ..metrics = const AudioRelayMetrics(signalLevel: 0.37);
    final controller = AudioRelayController(engine: engine);

    controller.activity = RelayActivity.streaming;
    await controller.pollMetricsForTesting();

    expect(controller.signalLevel, 0.37);

    controller.dispose();
  });

  test('audio profile parses receiver adaptive buffer setting', () {
    final profile = AudioProfile.fromMap({
      'mode': 'music',
      'sampleRate': 48000,
      'receiverAdaptiveBuffer': false,
    });

    expect(profile.mode, AudioPreset.music);
    expect(profile.toMap()['mode'], 'music');
    expect(profile.receiverAdaptiveBuffer, false);
    expect(profile.toMap()['receiverAdaptiveBuffer'], false);
  });

  test('audio profile parses adaptive format settings', () {
    final profile = AudioProfile.fromMap({
      'mode': 'balanced',
      'codec': 'opus',
      'sampleRate': 48000,
      'bitrateKbps': 128,
      'adaptiveSampleRate': 'true',
      'adaptiveBitrate': 1,
    });

    expect(profile.adaptiveSampleRate, true);
    expect(profile.adaptiveBitrate, true);
    expect(profile.toMap()['adaptiveSampleRate'], true);
    expect(profile.toMap()['adaptiveBitrate'], true);
  });

  test('output backend names parse platform aliases', () {
    expect(
      OutputAudioBackend.fromName('audio-track'),
      OutputAudioBackend.audioTrack,
    );
    expect(
      OutputAudioBackend.fromName('WASAPI shared'),
      OutputAudioBackend.wasapiShared,
    );
    expect(
      OutputAudioBackend.fromName('wasapi_exclusive'),
      OutputAudioBackend.wasapiExclusive,
    );
  });

  test(
    'initialize completion after dispose does not notify listeners',
    () async {
      final capabilitiesGate = Completer<void>();
      final controller = AudioRelayController(
        engine: _FakeAudioRelayEngine(
          capabilities: _supportedCapabilities,
          capabilitiesGate: capabilitiesGate,
        ),
        discoveryService: _FakeDiscoveryService(),
        profileStore: _FakeAudioProfileStore(),
        preferencesStore: _FakeAudioRelayPreferencesStore(),
        checkForUpdatesOnInitialize: false,
      );
      var notifications = 0;
      controller.addListener(() {
        notifications += 1;
      });

      final initialize = controller.initialize();
      controller.dispose();
      capabilitiesGate.complete();
      await initialize;

      expect(notifications, 0);
    },
  );

  test('update check reports an available platform release', () async {
    final release = _updateRelease(
      tagName: 'v1.0.5',
      assetName: 'AudioBridge-1.0.5-android.apk',
      target: AppUpdateTarget.android,
    );
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(),
      updateService: _FakeUpdateService(release: release),
      updateInstaller: _FakeUpdateInstaller(),
      appVersionProvider: () async => '1.0.4',
      updateTarget: AppUpdateTarget.android,
    );
    controller.appVersion = '1.0.4';

    await controller.checkForUpdates();

    expect(controller.updateStatus, AppUpdateStatus.available);
    expect(controller.availableUpdate?.tagName, 'v1.0.5');
    expect(controller.updateActionLabel, 'Download');
    expect(controller.updateCurrentVersionLabel, 'v1.0.4');
    expect(controller.updateLatestVersionLabel, 'v1.0.5');
    expect(controller.updateLatestVersionDetailLabel, 'Latest Android release');
    expect(controller.updatePackageLabel, 'AudioBridge-1.0.5-android.apk');
    expect(controller.updatePackageDetailLabel, '3 B Android package');
    expect(controller.updateDetailLabel, 'Current v1.0.4, latest v1.0.5.');

    controller.dispose();
  });

  test('initialize checks Codeberg releases automatically', () async {
    final updateService = _FakeUpdateService();
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(),
      discoveryService: _FakeDiscoveryService(),
      profileStore: _FakeAudioProfileStore(),
      preferencesStore: _FakeAudioRelayPreferencesStore(),
      updateService: updateService,
      appVersionProvider: () async => '1.1.0',
      updateTarget: AppUpdateTarget.windows,
    );

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(updateService.checkCount, 1);
    expect(controller.updateStatus, AppUpdateStatus.current);

    controller.dispose();
  });

  test('download update opens the downloaded package installer', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'audiobridge_update_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final packageFile = File('${tempDir.path}${Platform.pathSeparator}app.apk');
    await packageFile.writeAsBytes([1, 2, 3]);
    final release = _updateRelease(
      tagName: 'v1.0.5',
      assetName: 'AudioBridge-1.0.5-android.apk',
      target: AppUpdateTarget.android,
    );
    final installer = _FakeUpdateInstaller();
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(),
      updateService: _FakeUpdateService(
        release: release,
        downloadedFile: packageFile,
      ),
      updateInstaller: installer,
      appVersionProvider: () async => '1.0.4',
      updateTarget: AppUpdateTarget.android,
    );

    await controller.checkForUpdates();
    await controller.downloadAndInstallUpdate();

    expect(controller.updateStatus, AppUpdateStatus.ready);
    expect(controller.updateMessage, 'System installer opened.');
    expect(installer.installedPackages, [packageFile.path]);
    expect(controller.updateDownloadProgress, 1);

    controller.dispose();
  });

  test('aac is modeled as an implemented native codec path', () {
    expect(AudioCodec.aac.isImplemented, true);
    expect(AudioCodec.aac.availabilityLabel, 'Native required');

    const profile = AudioProfile(codec: AudioCodec.aac, bitrateKbps: 320);

    expect(profile.effectiveBitrateKbps, 192);
  });

  test('aac codec names parse common aliases', () {
    expect(AudioCodec.fromName('aac'), AudioCodec.aac);
    expect(AudioCodec.fromName('AAC-LC'), AudioCodec.aac);
    expect(AudioCodec.fromName('acc'), AudioCodec.aac);
  });

  test('opus is modeled as an implemented native codec path', () {
    expect(AudioCodec.opus.isImplemented, true);
    expect(AudioCodec.opus.availabilityLabel, 'Native required');

    const profile = AudioProfile(codec: AudioCodec.opus, bitrateKbps: 999);

    expect(profile.effectiveBitrateKbps, 256);
  });

  test('opus bitrate target is editable and clamped to codec range', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..capabilities = const PlatformAudioCapabilities(
        platform: 'test',
        canSend: true,
        canReceive: true,
        backend: 'fake',
        supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
        supportedOutputBackends: {OutputAudioBackend.auto},
        codecBitrateRanges: {
          AudioCodec.opus: CodecBitrateRange(minKbps: 64, maxKbps: 256),
        },
      );

    controller.updateCodec(AudioCodec.opus);
    controller.updateBitrate(128);

    expect(controller.hasBitrateTarget, true);
    expect(controller.bitrateTargetLabel, '128 kbps');
    expect(controller.profile.effectiveBitrateKbps, 128);

    controller.updateBitrate(999);

    expect(controller.bitrateTargetLabel, '256 kbps');
    expect(controller.profile.effectiveBitrateKbps, 256);

    controller.dispose();
  });

  test('manual format picks turn adaptive format settings off', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..capabilities = const PlatformAudioCapabilities(
        platform: 'test',
        canSend: true,
        canReceive: true,
        backend: 'fake',
        supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
        supportedOutputBackends: {OutputAudioBackend.auto},
        codecBitrateRanges: {
          AudioCodec.opus: CodecBitrateRange(minKbps: 64, maxKbps: 256),
        },
      );

    controller.updateAdaptiveSampleRate(true);
    controller.updateSampleRate(96000);
    controller.updateCodec(AudioCodec.opus);
    controller.updateAdaptiveBitrate(true);
    controller.updateBitrate(128);

    expect(controller.profile.adaptiveSampleRate, false);
    expect(controller.profile.sampleRate, 48000);
    expect(controller.profile.adaptiveBitrate, false);
    expect(controller.profile.bitrateKbps, 128);

    controller.dispose();
  });

  test(
    'adaptive stream matrix materializes every sender format axis',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller = AudioRelayController(engine: engine)
        ..role = RelayRole.sender
        ..capabilities = _adaptiveCodecCapabilities;

      controller.updatePreset(AudioPreset.music);
      controller.updateCodec(AudioCodec.aac);
      controller.updateAdaptiveSampleRate(true);
      controller.updateAdaptiveBitrate(true);
      await controller.startSenderStream();

      final startedProfile = engine.startedProfiles.single;
      expect(startedProfile.codec, AudioCodec.aac);
      expect(startedProfile.sampleRate, 96000);
      expect(startedProfile.bitrateKbps, 192);
      expect(startedProfile.adaptiveSampleRate, false);
      expect(startedProfile.adaptiveBitrate, false);
      expect(startedProfile.receiverAdaptiveBuffer, true);

      controller.dispose();
    },
  );

  test(
    'adaptive bitrate matrix uses recent transport pressure bands',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: _FakeDiscoveryService(),
              profileApplyDelay: Duration.zero,
            )
            ..role = RelayRole.sender
            ..capabilities = _adaptiveCodecCapabilities;

      controller.updateCodec(AudioCodec.opus);
      controller.updateAdaptiveBitrate(true);
      await controller.startSenderStream();

      engine.metrics = AudioRelayMetrics.empty;
      await controller.pollMetricsForTesting();
      await Future<void>.delayed(Duration.zero);

      Future<void> expectBitrateForDroppedPackets(
        int droppedPackets,
        int? expectedKbps,
      ) async {
        engine.calls.clear();
        engine.profiles.clear();
        engine.metrics = AudioRelayMetrics(droppedPacketCount: droppedPackets);
        await controller.pollMetricsForTesting();
        await Future<void>.delayed(Duration.zero);

        if (expectedKbps == null) {
          expect(engine.calls, isEmpty);
          expect(controller.streamBitrateLabel, '256 kbps');
          return;
        }

        expect(engine.calls, ['prepareSender']);
        expect(engine.profiles.single.bitrateKbps, expectedKbps);
        expect(controller.streamBitrateLabel, '$expectedKbps kbps');
      }

      await expectBitrateForDroppedPackets(1, null);
      await expectBitrateForDroppedPackets(7, 232);
      await expectBitrateForDroppedPackets(19, 208);
      await expectBitrateForDroppedPackets(43, 160);
      await expectBitrateForDroppedPackets(83, 64);

      controller.dispose();
    },
  );

  test('adaptive bitrate lowers on recent transport pressure', () async {
    final engine = _FakeAudioRelayEngine();
    final controller =
        AudioRelayController(
            engine: engine,
            discoveryService: _FakeDiscoveryService(),
            profileApplyDelay: Duration.zero,
          )
          ..role = RelayRole.sender
          ..capabilities = const PlatformAudioCapabilities(
            platform: 'test',
            canSend: true,
            canReceive: true,
            backend: 'fake',
            supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
            supportedOutputBackends: {OutputAudioBackend.auto},
            codecBitrateRanges: {
              AudioCodec.opus: CodecBitrateRange(minKbps: 64, maxKbps: 256),
            },
          );

    controller.updateCodec(AudioCodec.opus);
    controller.updateAdaptiveBitrate(true);
    await controller.startSenderStream();

    expect(controller.profile.adaptiveBitrate, true);
    expect(engine.startedProfiles.single.adaptiveBitrate, false);
    expect(engine.startedProfiles.single.bitrateKbps, 256);
    expect(controller.bitrateSettingDetailLabel, contains('64-256 kbps'));

    engine.metrics = AudioRelayMetrics.empty;
    await controller.pollMetricsForTesting();
    await Future<void>.delayed(Duration.zero);

    engine.calls.clear();
    engine.profiles.clear();
    engine.metrics = const AudioRelayMetrics(droppedPacketCount: 12);
    await controller.pollMetricsForTesting();
    await Future<void>.delayed(Duration.zero);

    expect(engine.calls, ['prepareSender']);
    expect(engine.profiles.single.bitrateKbps, 208);
    expect(controller.streamBitrateLabel, '208 kbps');

    engine.calls.clear();
    engine.profiles.clear();
    for (var index = 0; index < 6; index += 1) {
      await controller.pollMetricsForTesting();
      await Future<void>.delayed(Duration.zero);
    }

    expect(engine.calls, ['prepareSender']);
    expect(engine.profiles.single.bitrateKbps, 232);
    expect(controller.streamBitrateLabel, '232 kbps');

    controller.dispose();
  });

  test('receiver buffer pressure does not lower adaptive bitrate', () async {
    final engine = _FakeAudioRelayEngine();
    final controller =
        AudioRelayController(
            engine: engine,
            discoveryService: _FakeDiscoveryService(),
            profileApplyDelay: Duration.zero,
          )
          ..role = RelayRole.sender
          ..capabilities = const PlatformAudioCapabilities(
            platform: 'test',
            canSend: true,
            canReceive: true,
            backend: 'fake',
            supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
            supportedOutputBackends: {OutputAudioBackend.auto},
            codecBitrateRanges: {
              AudioCodec.opus: CodecBitrateRange(minKbps: 64, maxKbps: 256),
            },
          );

    controller.updateCodec(AudioCodec.opus);
    controller.updateAdaptiveBitrate(true);
    await controller.startSenderStream();

    engine.metrics = AudioRelayMetrics.empty;
    await controller.pollMetricsForTesting();
    await Future<void>.delayed(Duration.zero);

    engine.calls.clear();
    engine.profiles.clear();
    engine.metrics = const AudioRelayMetrics(
      adaptiveLimitReached: true,
      adaptiveUnderrunsInWindow: 4,
      adaptiveLowQueueSamples: 3,
      trimCount: 12,
    );
    await controller.pollMetricsForTesting();
    await Future<void>.delayed(Duration.zero);

    expect(engine.calls, isEmpty);
    expect(controller.streamBitrateLabel, '256 kbps');

    controller.dispose();
  });

  test(
    'receiver adaptive toggle preserves concrete sender format while streaming',
    () async {
      final engine = _FakeAudioRelayEngine();
      final discoveryService = _FakeDiscoveryService();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: discoveryService,
              profileApplyDelay: Duration.zero,
            )
            ..role = RelayRole.sender
            ..capabilities = const PlatformAudioCapabilities(
              platform: 'test',
              canSend: true,
              canReceive: true,
              backend: 'fake',
              supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
              supportedOutputBackends: {OutputAudioBackend.auto},
              codecBitrateRanges: {
                AudioCodec.opus: CodecBitrateRange(minKbps: 64, maxKbps: 256),
              },
            );

      controller.updateCodec(AudioCodec.opus);
      controller.updateAdaptiveBitrate(true);
      await controller.startSenderStream();
      final startedProfile = engine.startedProfiles.single;
      engine.calls.clear();
      engine.profiles.clear();
      discoveryService.advertisedProfiles.clear();

      engine.metrics = const AudioRelayMetrics(
        adaptiveLimitReached: true,
        adaptiveUnderrunsInWindow: 4,
        adaptiveLowQueueSamples: 3,
      );
      controller.updateReceiverAdaptiveBuffer(false);
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.codec, startedProfile.codec);
      expect(engine.profiles.single.sampleRate, startedProfile.sampleRate);
      expect(engine.profiles.single.bitrateKbps, startedProfile.bitrateKbps);
      expect(engine.profiles.single.packetTimeMs, startedProfile.packetTimeMs);
      expect(engine.profiles.single.receiverAdaptiveBuffer, false);
      expect(
        discoveryService.advertisedProfiles.single.bitrateKbps,
        startedProfile.bitrateKbps,
      );

      controller.dispose();
    },
  );

  test(
    'live buffering changes resolve together without format side effects',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: _FakeDiscoveryService(),
              profileApplyDelay: Duration.zero,
            )
            ..role = RelayRole.sender
            ..capabilities = const PlatformAudioCapabilities(
              platform: 'test',
              canSend: true,
              canReceive: true,
              backend: 'fake',
              supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
              supportedOutputBackends: {OutputAudioBackend.auto},
              codecBitrateRanges: {
                AudioCodec.opus: CodecBitrateRange(minKbps: 64, maxKbps: 256),
              },
            );

      controller.updateCodec(AudioCodec.opus);
      controller.updateAdaptiveBitrate(true);
      await controller.startSenderStream();
      final startedProfile = engine.startedProfiles.single;
      engine.calls.clear();
      engine.profiles.clear();

      controller.updatePlaybackBuffer(24);
      controller.updatePacketTime(2);
      controller.updateReceiverAdaptiveBuffer(false);
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.codec, startedProfile.codec);
      expect(engine.profiles.single.sampleRate, startedProfile.sampleRate);
      expect(engine.profiles.single.bitrateKbps, startedProfile.bitrateKbps);
      expect(engine.profiles.single.playbackBufferMs, 24);
      expect(engine.profiles.single.packetTimeMs, 2);
      expect(engine.profiles.single.receiverAdaptiveBuffer, false);

      controller.dispose();
    },
  );

  test(
    'custom preset applies to active sender as live receiver policy',
    () async {
      final engine = _FakeAudioRelayEngine();
      final discoveryService = _FakeDiscoveryService();
      final controller = AudioRelayController(
        engine: engine,
        discoveryService: discoveryService,
        profileApplyDelay: Duration.zero,
      )..role = RelayRole.sender;

      controller.updatePlaybackBuffer(72);
      controller.saveCustomPreset();
      controller.updateAdaptiveBufferCap(180);
      controller.updatePreset(AudioPreset.balanced);
      await controller.startSenderStream();
      final startedProfile = engine.startedProfiles.single;
      engine.calls.clear();
      engine.profiles.clear();
      discoveryService.advertisedProfiles.clear();

      controller.updatePreset(AudioPreset.custom);
      await Future<void>.delayed(Duration.zero);

      expect(controller.selectedPreset, AudioPreset.custom);
      expect(controller.profile.mode, AudioPreset.custom);
      expect(controller.profile.sampleRate, startedProfile.sampleRate);
      expect(
        controller.profile.captureBufferMs,
        startedProfile.captureBufferMs,
      );
      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.mode, AudioPreset.custom);
      expect(engine.profiles.single.sampleRate, startedProfile.sampleRate);
      expect(
        engine.profiles.single.captureBufferMs,
        startedProfile.captureBufferMs,
      );
      expect(engine.profiles.single.playbackBufferMs, 72);
      expect(engine.profiles.single.adaptiveBufferCapMs, 180);
      expect(
        discoveryService.advertisedProfiles.single.mode,
        AudioPreset.custom,
      );

      controller.dispose();
    },
  );

  test(
    'music preset applies to active sender as live receiver policy',
    () async {
      final engine = _FakeAudioRelayEngine();
      final discoveryService = _FakeDiscoveryService();
      final controller = AudioRelayController(
        engine: engine,
        discoveryService: discoveryService,
        profileApplyDelay: Duration.zero,
      )..role = RelayRole.sender;

      await controller.startSenderStream();
      final startedProfile = engine.startedProfiles.single;
      engine.calls.clear();
      engine.profiles.clear();
      discoveryService.advertisedProfiles.clear();

      controller.updatePreset(AudioPreset.music);
      await Future<void>.delayed(Duration.zero);

      expect(controller.selectedPreset, AudioPreset.music);
      expect(controller.profile.mode, AudioPreset.music);
      expect(controller.profile.sampleRate, startedProfile.sampleRate);
      expect(
        controller.profile.captureBufferMs,
        startedProfile.captureBufferMs,
      );
      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.mode, AudioPreset.music);
      expect(engine.profiles.single.sampleRate, startedProfile.sampleRate);
      expect(
        engine.profiles.single.captureBufferMs,
        startedProfile.captureBufferMs,
      );
      expect(engine.profiles.single.playbackBufferMs, 320);
      expect(engine.profiles.single.packetTimeMs, 12);
      expect(
        discoveryService.advertisedProfiles.single.mode,
        AudioPreset.music,
      );

      controller.dispose();
    },
  );

  test('adaptive sample rate materializes a concrete sender rate', () async {
    final engine = _FakeAudioRelayEngine();
    final controller = AudioRelayController(engine: engine)
      ..role = RelayRole.sender
      ..metrics = const AudioRelayMetrics(
        adaptiveLimitReached: true,
        adaptiveUnderrunsInWindow: 4,
        adaptiveLowQueueSamples: 3,
      );

    controller.updateAdaptiveSampleRate(true);
    await controller.startSenderStream();

    expect(controller.profile.adaptiveSampleRate, true);
    expect(engine.startedProfiles.single.adaptiveSampleRate, false);
    expect(engine.startedProfiles.single.sampleRate, 48000);
    expect(controller.sampleRateLabel, 'Adaptive (48 kHz)');
    expect(
      controller.sampleRateSettingDetailLabel,
      contains('44.1 kHz-96 kHz'),
    );

    controller.dispose();
  });

  test(
    'pcm bitrate is calculated and ignores manual bitrate target changes',
    () {
      final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
        ..role = RelayRole.sender
        ..capabilities = _supportedCapabilities;

      controller.updateBitrate(128);

      expect(controller.hasBitrateTarget, false);
      expect(controller.streamBitrateLabel, '1536 kbps');
      expect(
        controller.profile.bitrateKbps,
        AudioPreset.balanced.profile.bitrateKbps,
      );

      controller.dispose();
    },
  );

  test('auto codec is a controller policy, not a packet codec', () {
    expect(AudioCodec.auto.isImplemented, true);
    expect(AudioCodec.auto.label, 'Adaptive');
    expect(AudioCodec.auto.packetId, -1);
    expect(AudioCodec.fromName('auto'), AudioCodec.auto);
    expect(AudioCodec.fromName('adaptive'), AudioCodec.auto);
    expect(AudioCodec.fromPacketId(-1), AudioCodec.pcm);
  });

  test('capabilities parse aac support from the native backend', () {
    final capabilities = PlatformAudioCapabilities.fromMap({
      'platform': 'test',
      'canSend': true,
      'canReceive': true,
      'backend': 'fake',
      'supportedCodecs': ['pcm', 'aac'],
      'codecBitrateRanges': {
        'aac': {'minKbps': 96, 'maxKbps': 192},
      },
    });

    expect(capabilities.supportsCodec(AudioCodec.aac), true);
    expect(capabilities.codecBitrateRanges[AudioCodec.aac]?.minKbps, 96);
    expect(capabilities.codecBitrateRanges[AudioCodec.aac]?.maxKbps, 192);
  });

  test('capabilities parse opus support from the native backend', () {
    final capabilities = PlatformAudioCapabilities.fromMap({
      'platform': 'test',
      'canSend': true,
      'canReceive': true,
      'backend': 'fake',
      'supportedCodecs': ['pcm', 'opus', 'aac'],
      'codecBitrateRanges': {
        'opus': {'minKbps': 64, 'maxKbps': 256},
      },
    });

    expect(capabilities.supportsCodec(AudioCodec.opus), true);
    expect(capabilities.codecBitrateRanges[AudioCodec.opus]?.minKbps, 64);
    expect(capabilities.codecBitrateRanges[AudioCodec.opus]?.maxKbps, 256);
  });

  test('relay transport parses USB tethering aliases', () {
    expect(
      RelayTransport.fromName('usbTethering'),
      RelayTransport.usbTethering,
    );
    expect(
      RelayTransport.fromName('usb-tethering'),
      RelayTransport.usbTethering,
    );
    expect(RelayTransport.fromName('tethering'), RelayTransport.usbTethering);
  });

  test('usb tethering discovery uses datagram source host', () {
    final device = RelayDevice.fromDiscoveryMap({
      'type': 'audiobridge.source',
      'id': 'source-1',
      'name': 'Windows source',
      'host': '192.168.1.25',
      'port': DiscoveryService.audioPort,
      'transport': 'usbTethering',
      'platform': 'windows',
      'profile': AudioProfile.usbTetheringLowLatency.toMap(),
    }, sourceHost: '192.168.42.129');

    expect(device?.transport, RelayTransport.usbTethering);
    expect(device?.host, '192.168.42.129');
  });

  test(
    'network scoped local address separates wifi and usb tethering',
    () async {
      final service = DiscoveryService(
        interfacesProvider: () async => [
          DiscoveryNetworkInterface(
            name: 'Wi-Fi',
            description: 'Intel(R) Wi-Fi 6',
            addresses: [InternetAddress('192.168.1.130')],
          ),
          DiscoveryNetworkInterface(
            name: 'Ethernet 2',
            description: 'Remote NDIS based Internet Sharing Device',
            addresses: [InternetAddress('192.168.11.87')],
          ),
        ],
      );

      expect(
        await service.localIPv4Address(scope: DiscoveryNetworkScope.wifi),
        '192.168.1.130',
      );
      expect(
        await service.localIPv4Address(
          scope: DiscoveryNetworkScope.usbTethering,
        ),
        '192.168.11.87',
      );
    },
  );

  test('usb tethering scope recognizes Android rndis interface', () async {
    final service = DiscoveryService(
      interfacesProvider: () async => [
        DiscoveryNetworkInterface(
          name: 'wlan0',
          description: 'wlan0',
          addresses: [InternetAddress('192.168.1.129')],
        ),
        DiscoveryNetworkInterface(
          name: 'rndis0',
          description: 'rndis0',
          addresses: [InternetAddress('192.168.11.49')],
        ),
      ],
    );

    expect(
      await service.localIPv4Address(scope: DiscoveryNetworkScope.wifi),
      '192.168.1.129',
    );
    expect(
      await service.localIPv4Address(scope: DiscoveryNetworkScope.usbTethering),
      '192.168.11.49',
    );
  });

  test('scoped discovery receive binds wildcard for broadcast delivery', () {
    final service = DiscoveryService();

    final usbBindAddresses = service.debugReceiveBindAddresses(
      DiscoveryNetworkScope.usbTethering,
      [InternetAddress('192.168.11.49')],
    );
    final wifiBindAddresses = service.debugReceiveBindAddresses(
      DiscoveryNetworkScope.wifi,
      [InternetAddress('192.168.1.129')],
    );

    expect(usbBindAddresses.single.address, InternetAddress.anyIPv4.address);
    expect(wifiBindAddresses.single.address, InternetAddress.anyIPv4.address);
  });

  test('cidr discovery computes non-class-c broadcast targets', () {
    final service = DiscoveryService();
    final address = DiscoveryNetworkAddress(
      address: InternetAddress('172.16.5.9'),
      prefixLength: 16,
    );

    expect(
      service.debugDirectedBroadcastAddress(address)?.address,
      '172.16.255.255',
    );
    expect(
      service.debugSourceMatchesScope(InternetAddress('172.16.99.2'), [
        address,
      ]),
      true,
    );
    expect(
      service.debugSourceMatchesScope(InternetAddress('172.17.1.2'), [address]),
      false,
    );
  });

  test('cidr discovery handles twenty-bit prefixes', () {
    final service = DiscoveryService();
    final address = DiscoveryNetworkAddress(
      address: InternetAddress('10.20.16.8'),
      prefixLength: 20,
    );

    expect(
      service.debugDirectedBroadcastAddress(address)?.address,
      '10.20.31.255',
    );
    expect(
      service.debugSourceMatchesScope(InternetAddress('10.20.31.99'), [
        address,
      ]),
      true,
    );
    expect(
      service.debugSourceMatchesScope(InternetAddress('10.20.32.1'), [address]),
      false,
    );
  });

  test('wifi discovery uses datagram source host', () {
    final device = RelayDevice.fromDiscoveryMap({
      'type': 'audiobridge.source',
      'id': 'source-1',
      'name': 'Windows source',
      'host': '192.168.42.129',
      'port': DiscoveryService.audioPort,
      'transport': 'wifi',
      'platform': 'windows',
      'profile': AudioPreset.balanced.profile.toMap(),
    }, sourceHost: '192.168.1.25');

    expect(device?.transport, RelayTransport.wifi);
    expect(device?.host, '192.168.1.25');
  });

  test('selecting opus normalizes the profile to 48 kHz', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..capabilities = const PlatformAudioCapabilities(
        platform: 'test',
        canSend: true,
        canReceive: true,
        backend: 'fake',
        supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
        supportedOutputBackends: {OutputAudioBackend.auto},
        codecBitrateRanges: {},
      );

    controller.updateSampleRate(96000);
    controller.updateCodec(AudioCodec.opus);

    expect(controller.profile.codec, AudioCodec.opus);
    expect(controller.profile.sampleRate, 48000);

    controller.dispose();
  });

  test('opus packet label reports the effective low delay frame size', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..capabilities = const PlatformAudioCapabilities(
        platform: 'test',
        canSend: true,
        canReceive: true,
        backend: 'fake',
        supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
        supportedOutputBackends: {OutputAudioBackend.auto},
        codecBitrateRanges: {},
      );

    controller.updatePreset(AudioPreset.gaming);
    controller.updateCodec(AudioCodec.opus);

    expect(controller.profile.packetTimeMs, 1);
    expect(controller.packetFramesLabel, '120 frames per packet · 2.5 ms Opus');

    controller.dispose();
  });

  test('opus profile ignores non-48 kHz sample rate changes', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..capabilities = const PlatformAudioCapabilities(
        platform: 'test',
        canSend: true,
        canReceive: true,
        backend: 'fake',
        supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
        supportedOutputBackends: {OutputAudioBackend.auto},
        codecBitrateRanges: {},
      );

    controller.updateCodec(AudioCodec.opus);
    controller.updateSampleRate(96000);

    expect(controller.profile.codec, AudioCodec.opus);
    expect(controller.profile.sampleRate, 48000);

    controller.dispose();
  });

  test('auto codec starts sender with concrete pcm profile', () async {
    final engine = _FakeAudioRelayEngine();
    final controller = AudioRelayController(engine: engine)
      ..role = RelayRole.sender
      ..capabilities = const PlatformAudioCapabilities(
        platform: 'test',
        canSend: true,
        canReceive: true,
        backend: 'fake',
        supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
        supportedOutputBackends: {OutputAudioBackend.auto},
        codecBitrateRanges: {},
      );

    controller.updateCodec(AudioCodec.auto);
    await controller.startSenderStream();

    expect(controller.profile.codec, AudioCodec.auto);
    expect(engine.profiles.first.codec, AudioCodec.pcm);
    expect(engine.startedProfiles.single.codec, AudioCodec.pcm);

    controller.dispose();
  });

  test(
    'gaming auto codec starts with opus when receiver support is known',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller = AudioRelayController(engine: engine)
        ..role = RelayRole.sender
        ..capabilities = const PlatformAudioCapabilities(
          platform: 'test',
          canSend: true,
          canReceive: true,
          backend: 'fake',
          supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
          supportedOutputBackends: {OutputAudioBackend.auto},
          codecBitrateRanges: {},
        );

      controller.updatePreset(AudioPreset.gaming);
      controller.updateCodec(AudioCodec.auto);
      controller.metrics = const AudioRelayMetrics(
        remoteSupportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
      );
      await controller.startSenderStream();

      expect(controller.profile.codec, AudioCodec.auto);
      expect(engine.profiles.first.codec, AudioCodec.opus);
      expect(engine.startedProfiles.single.codec, AudioCodec.opus);
      expect(controller.codecStatusLabel, 'Adaptive (Opus)');
      expect(controller.streamBitrateLabel, '256 kbps');

      controller.dispose();
    },
  );

  test(
    'gaming auto codec prefers low-delay adpcm over aac without opus',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller = AudioRelayController(engine: engine)
        ..role = RelayRole.sender
        ..capabilities = const PlatformAudioCapabilities(
          platform: 'test',
          canSend: true,
          canReceive: true,
          backend: 'fake',
          supportedCodecs: {
            AudioCodec.pcm,
            AudioCodec.aac,
            AudioCodec.imaAdpcm,
          },
          supportedOutputBackends: {OutputAudioBackend.auto},
          codecBitrateRanges: {},
        );

      controller.updatePreset(AudioPreset.gaming);
      controller.updateCodec(AudioCodec.auto);
      controller.metrics = const AudioRelayMetrics(
        remoteSupportedCodecs: {
          AudioCodec.pcm,
          AudioCodec.aac,
          AudioCodec.imaAdpcm,
        },
      );
      await controller.startSenderStream();

      expect(controller.profile.codec, AudioCodec.auto);
      expect(engine.profiles.first.codec, AudioCodec.imaAdpcm);
      expect(engine.startedProfiles.single.codec, AudioCodec.imaAdpcm);
      expect(controller.codecStatusLabel, 'Adaptive (IMA ADPCM)');

      controller.dispose();
    },
  );

  test(
    'gaming auto codec upgrades to opus as soon as receiver supports it',
    () async {
      final engine = _FakeAudioRelayEngine();
      final discoveryService = _FakeDiscoveryService();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: discoveryService,
            )
            ..role = RelayRole.sender
            ..capabilities = const PlatformAudioCapabilities(
              platform: 'test',
              canSend: true,
              canReceive: true,
              backend: 'fake',
              supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
              supportedOutputBackends: {OutputAudioBackend.auto},
              codecBitrateRanges: {},
            );

      controller.updatePreset(AudioPreset.gaming);
      controller.updateCodec(AudioCodec.auto);
      await controller.startSenderStream();

      expect(engine.startedProfiles.single.codec, AudioCodec.pcm);
      engine.calls.clear();
      engine.profiles.clear();
      discoveryService.advertisedProfiles.clear();

      engine.metrics = const AudioRelayMetrics(
        signalLevel: 0.8,
        remoteSupportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
      );
      await controller.pollMetricsForTesting();
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.codec, AudioCodec.opus);
      expect(discoveryService.advertisedProfiles.single.codec, AudioCodec.opus);
      expect(controller.codecStatusLabel, 'Adaptive (Opus)');

      controller.dispose();
    },
  );

  test(
    'manual codec falls back to pcm when receiver does not support it',
    () async {
      final engine = _FakeAudioRelayEngine();
      final discoveryService = _FakeDiscoveryService();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: discoveryService,
              profileApplyDelay: Duration.zero,
            )
            ..role = RelayRole.sender
            ..capabilities = const PlatformAudioCapabilities(
              platform: 'test',
              canSend: true,
              canReceive: true,
              backend: 'fake',
              supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
              supportedOutputBackends: {OutputAudioBackend.auto},
              codecBitrateRanges: {},
            );

      controller.updateCodec(AudioCodec.opus);
      await controller.startSenderStream();

      expect(engine.startedProfiles.single.codec, AudioCodec.opus);
      engine.calls.clear();
      engine.profiles.clear();
      discoveryService.advertisedProfiles.clear();

      engine.metrics = const AudioRelayMetrics(
        remoteSupportedCodecs: {AudioCodec.pcm},
      );
      await controller.pollMetricsForTesting();

      expect(controller.profile.codec, AudioCodec.pcm);
      expect(controller.noticeMessage, contains('switched to PCM'));
      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.codec, AudioCodec.pcm);
      expect(discoveryService.advertisedProfiles.single.codec, AudioCodec.pcm);

      controller.dispose();
    },
  );

  test(
    'auto codec switches after warmup only when receiver is quiet',
    () async {
      final engine = _FakeAudioRelayEngine();
      final discoveryService = _FakeDiscoveryService();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: discoveryService,
              profileApplyDelay: Duration.zero,
              autoCodecWarmup: Duration.zero,
              autoCodecQuietHold: Duration.zero,
            )
            ..role = RelayRole.sender
            ..capabilities = const PlatformAudioCapabilities(
              platform: 'test',
              canSend: true,
              canReceive: true,
              backend: 'fake',
              supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
              supportedOutputBackends: {OutputAudioBackend.auto},
              codecBitrateRanges: {},
            );

      controller.updateCodec(AudioCodec.auto);
      await controller.startSenderStream();
      engine.calls.clear();
      engine.profiles.clear();
      discoveryService.advertisedProfiles.clear();

      engine.metrics = const AudioRelayMetrics(
        signalLevel: 0.4,
        adaptiveUnderrunsInWindow: 4,
        adaptivePlaybackBufferMs: 64,
        remoteSupportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
      );
      await controller.pollMetricsForTesting();
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, isEmpty);

      engine.metrics = const AudioRelayMetrics(
        signalLevel: 0.001,
        adaptiveUnderrunsInWindow: 4,
        adaptivePlaybackBufferMs: 64,
        remoteSupportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
      );
      await controller.pollMetricsForTesting();
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, ['prepareSender']);
      expect(engine.profiles.single.codec, AudioCodec.opus);
      expect(discoveryService.advertisedProfiles.single.codec, AudioCodec.opus);
      expect(controller.profile.codec, AudioCodec.auto);
      expect(controller.codecStatusLabel, 'Adaptive (Opus)');

      controller.dispose();
    },
  );

  test('auto codec keeps pcm until receiver codec support is known', () async {
    final engine = _FakeAudioRelayEngine();
    final controller =
        AudioRelayController(
            engine: engine,
            autoCodecWarmup: Duration.zero,
            autoCodecQuietHold: Duration.zero,
          )
          ..role = RelayRole.sender
          ..capabilities = const PlatformAudioCapabilities(
            platform: 'test',
            canSend: true,
            canReceive: true,
            backend: 'fake',
            supportedCodecs: {AudioCodec.pcm, AudioCodec.opus},
            supportedOutputBackends: {OutputAudioBackend.auto},
            codecBitrateRanges: {},
          );

    controller.updateCodec(AudioCodec.auto);
    await controller.startSenderStream();
    engine.calls.clear();
    engine.profiles.clear();

    engine.metrics = const AudioRelayMetrics(
      signalLevel: 0.001,
      adaptiveUnderrunsInWindow: 4,
      adaptivePlaybackBufferMs: 64,
    );
    await controller.pollMetricsForTesting();
    await Future<void>.delayed(Duration.zero);

    expect(engine.calls, isEmpty);
    expect(controller.codecStatusLabel, 'Adaptive (PCM)');

    controller.dispose();
  });

  test(
    'soundboard queues selected sound into an active sender stream',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller = AudioRelayController(engine: engine)
        ..role = RelayRole.sender
        ..capabilities = _soundboardCapabilities;
      const soundPath = r'C:\sounds\airhorn.mp3';

      controller.addSoundboardFiles([soundPath]);
      controller.updateSoundboardTarget(SoundboardPlaybackTarget.stream);

      expect(controller.selectedSoundboardItem?.name, 'airhorn.mp3');
      expect(controller.canPlaySelectedSound, false);

      await controller.playSelectedSoundboardItem();

      expect(engine.soundEffectPaths, isEmpty);
      expect(controller.soundboardMessage, 'Start sender streaming first.');

      await controller.startSenderStream();
      engine.calls.clear();
      controller.updateSoundboardVolume(0.5);
      await controller.playSelectedSoundboardItem();

      expect(engine.calls, ['playSoundEffect']);
      expect(engine.soundEffectPaths, [soundPath]);
      expect(engine.soundEffectVolumes, [0.5]);
      expect(engine.soundEffectTargets, [SoundboardPlaybackTarget.stream]);

      controller.dispose();
    },
  );

  test('soundboard mic route can play without sender streaming', () async {
    final engine = _FakeAudioRelayEngine();
    final controller = AudioRelayController(engine: engine)
      ..role = RelayRole.sender
      ..capabilities = _soundboardCapabilities;
    controller.selectSoundboardOutputDevice('route-1');
    const soundPath = r'C:\sounds\airhorn.mp3';

    controller.addSoundboardFiles([soundPath]);
    await controller.playSelectedSoundboardItem();

    expect(engine.virtualMicPassthroughEnabled, [true]);
    expect(engine.virtualMicPassthroughOutputDeviceIds, ['route-1']);
    expect(engine.calls, ['playSoundEffect']);
    expect(engine.soundEffectTargets, [SoundboardPlaybackTarget.micRoute]);
    expect(engine.soundEffectOutputDeviceIds, ['route-1']);

    controller.dispose();
  });

  test('soundboard virtual mic bridges the real microphone into the route', () {
    final engine = _FakeAudioRelayEngine();
    final controller = AudioRelayController(engine: engine)
      ..role = RelayRole.sender
      ..capabilities = _soundboardCapabilities;

    controller.selectSoundboardOutputDevice('route-1');
    controller.updateSoundboardTarget(SoundboardPlaybackTarget.stream);
    controller.updateSoundboardTarget(SoundboardPlaybackTarget.micRoute);

    expect(engine.virtualMicPassthroughEnabled, [true, false, true]);
    expect(engine.virtualMicPassthroughOutputDeviceIds, [
      'route-1',
      null,
      'route-1',
    ]);

    controller.dispose();
  });

  test('soundboard virtual mic hides physical output devices', () async {
    final engine = _FakeAudioRelayEngine();
    final controller = AudioRelayController(engine: engine)
      ..role = RelayRole.sender
      ..capabilities = _soundboardPhysicalOnlyCapabilities;
    const soundPath = r'C:\sounds\airhorn.mp3';

    controller.addSoundboardFiles([soundPath]);

    expect(controller.soundboardOutputDevices, isEmpty);
    expect(controller.canPlaySelectedSound, false);
    expect(controller.soundboardStatusLabel, 'Needs call mic');

    await controller.playSelectedSoundboardItem();

    expect(engine.calls, isEmpty);
    expect(controller.soundboardMessage, 'Install or enable VB-CABLE first.');

    controller.dispose();
  });

  test('soundboard virtual mic prefers direct cable routes', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..capabilities = _soundboardMixedVirtualCapabilities;

    expect(controller.soundboardOutputDevices, hasLength(1));
    expect(controller.soundboardOutputDevices.single.id, 'cable-2');
    expect(
      controller.soundboardOutputDevices.single.name,
      'CABLE Input (VB-Audio Virtual Cable)',
    );
    expect(
      controller.callMicrophoneNameForSoundboardRoute(
        controller.soundboardOutputDevices.single,
      ),
      'CABLE Output (VB-Audio Virtual Cable)',
    );

    controller.dispose();
  });

  test(
    'usb buffering label reports adaptive receiver target while streaming',
    () {
      final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
        ..transport = RelayTransport.usb
        ..activity = RelayActivity.streaming
        ..metrics = const AudioRelayMetrics(adaptivePlaybackBufferMs: 10);

      expect(controller.bufferingLabel, '10 ms active');

      controller.dispose();
    },
  );

  test('native usb receiver starts without Wi-Fi scanning', () async {
    final engine = _FakeAudioRelayEngine();
    final discoveryService = _FakeDiscoveryService();
    final controller =
        AudioRelayController(engine: engine, discoveryService: discoveryService)
          ..role = RelayRole.receiver
          ..capabilities = _supportedCapabilities;

    await controller.setTransport(RelayTransport.usb);
    await controller.startDiscovery();

    expect(controller.activity, RelayActivity.streaming);
    expect(controller.devices, isEmpty);
    expect(controller.selectedDevice, isNull);
    expect(discoveryService.scanningStarted, false);
    expect(engine.calls, ['prepareUsbReceiver', 'startStream']);

    controller.dispose();
  });

  test('native usb receiver exposes Windows cable source', () async {
    final controller =
        AudioRelayController(
            engine: _FakeAudioRelayEngine(),
            discoveryService: _FakeDiscoveryService(),
          )
          ..role = RelayRole.receiver
          ..capabilities = _androidSupportedCapabilities;

    await controller.setTransport(RelayTransport.usb);

    expect(controller.visibleDevices, hasLength(1));
    expect(controller.visibleDevices.single.id, 'native-usb-source');
    expect(controller.visibleDevices.single.name, 'Windows USB host');
    expect(controller.visibleDevices.single.platform, DevicePlatform.windows);
    expect(controller.connectionTarget?.id, 'native-usb-source');
    expect(controller.isDeviceSelected(controller.visibleDevices.single), true);

    controller.dispose();
  });

  test(
    'native usb receiver connects through direct USB receiver path',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: _FakeDiscoveryService(),
            )
            ..role = RelayRole.receiver
            ..capabilities = _androidSupportedCapabilities;

      await controller.setTransport(RelayTransport.usb);
      await controller.connectToDevice(controller.connectionTarget!);

      expect(controller.activity, RelayActivity.streaming);
      expect(engine.calls, ['prepareUsbReceiver', 'startStream']);

      controller.dispose();
    },
  );

  test('usb sender prepares the usb native transport', () async {
    final engine = _FakeAudioRelayEngine();
    final controller =
        AudioRelayController(
            engine: engine,
            discoveryService: _FakeDiscoveryService(),
          )
          ..role = RelayRole.sender
          ..capabilities = _supportedCapabilities;

    await controller.setTransport(RelayTransport.usb);
    await controller.startDiscovery();

    expect(engine.calls, ['prepareUsbSender']);
    expect(
      engine.profiles.single.hasSameSettings(
        AudioProfile.usbLowLatency.copyWith(codec: AudioCodec.pcm),
      ),
      true,
    );
    expect(controller.profile.codec, AudioCodec.auto);
    expect(controller.activity, RelayActivity.advertising);

    controller.dispose();
  });

  test('usb transport applies and leaves its low latency profile', () async {
    final controller = AudioRelayController(
      engine: _FakeAudioRelayEngine(),
      discoveryService: _FakeDiscoveryService(),
    )..capabilities = _supportedCapabilities;

    await controller.setTransport(RelayTransport.usb);

    expect(
      controller.profile.hasSameSettings(AudioProfile.usbLowLatency),
      true,
    );
    expect(controller.selectedPreset, AudioPreset.gaming);
    expect(controller.profile.mode, AudioPreset.gaming);
    expect(controller.presetLabel, 'Native USB low latency');

    controller.updateReceiverAdaptiveBuffer(false);
    expect(controller.presetLabel, 'Native USB low latency');

    await controller.setTransport(RelayTransport.wifi);

    expect(
      controller.profile.hasSameSettings(AudioPreset.balanced.profile),
      true,
    );
    expect(controller.selectedPreset, AudioPreset.balanced);

    controller.dispose();
  });

  test(
    'usb tethering transport applies and leaves its network profile',
    () async {
      final controller = AudioRelayController(
        engine: _FakeAudioRelayEngine(),
        discoveryService: _FakeDiscoveryService(),
      )..capabilities = _supportedCapabilities;

      await controller.setTransport(RelayTransport.usbTethering);

      expect(
        controller.profile.hasSameSettings(AudioProfile.usbTetheringLowLatency),
        true,
      );
      expect(controller.selectedPreset, AudioPreset.gaming);
      expect(controller.profile.mode, AudioPreset.gaming);
      expect(controller.presetLabel, 'USB tethering low latency');

      await controller.setTransport(RelayTransport.wifi);

      expect(
        controller.profile.hasSameSettings(AudioPreset.balanced.profile),
        true,
      );
      expect(controller.selectedPreset, AudioPreset.balanced);

      controller.dispose();
    },
  );

  test('usb tethering sender advertises over network discovery', () async {
    final engine = _FakeAudioRelayEngine();
    final discoveryService = _FakeDiscoveryService();
    final controller =
        AudioRelayController(engine: engine, discoveryService: discoveryService)
          ..role = RelayRole.sender
          ..capabilities = _supportedCapabilities;

    await controller.setTransport(RelayTransport.usbTethering);
    await controller.startDiscovery();

    expect(engine.calls, ['prepareSender']);
    expect(engine.senderBindAddresses.single, '192.168.11.87');
    expect(
      engine.profiles.single.hasSameSettings(
        AudioProfile.usbTetheringLowLatency.copyWith(codec: AudioCodec.pcm),
      ),
      true,
    );
    expect(controller.profile.codec, AudioCodec.auto);
    expect(
      discoveryService.advertisedDevices.single.transport,
      RelayTransport.usbTethering,
    );
    expect(discoveryService.advertisedDevices.single.host, '192.168.11.87');
    expect(
      discoveryService.advertisedScopes.single,
      DiscoveryNetworkScope.usbTethering,
    );
    expect(controller.activity, RelayActivity.advertising);

    controller.dispose();
  });

  test(
    'usb tethering receiver scans instead of creating localhost source',
    () async {
      final discoveryService = _FakeDiscoveryService();
      final controller =
          AudioRelayController(
              engine: _FakeAudioRelayEngine(),
              discoveryService: discoveryService,
            )
            ..role = RelayRole.receiver
            ..capabilities = _supportedCapabilities;

      await controller.setTransport(RelayTransport.usbTethering);
      await controller.startDiscovery();

      expect(controller.activity, RelayActivity.scanning);
      expect(controller.devices, isEmpty);
      expect(discoveryService.scanningStarted, true);
      expect(
        discoveryService.scanningScopes.single,
        DiscoveryNetworkScope.usbTethering,
      );

      controller.dispose();
    },
  );

  test('receiver scan auto-pauses when no connection is made', () async {
    final discoveryService = _FakeDiscoveryService();
    final controller =
        AudioRelayController(
            engine: _FakeAudioRelayEngine(),
            discoveryService: discoveryService,
            discoveryIdleTimeout: Duration.zero,
          )
          ..role = RelayRole.receiver
          ..capabilities = _supportedCapabilities;

    await controller.startDiscovery();
    await _pumpEventQueue();

    expect(controller.activity, RelayActivity.idle);
    expect(discoveryService.scanningStarted, false);
    expect(
      controller.noticeMessage,
      'Paused receiver discovery after a moment without a connection.',
    );

    controller.dispose();
  });

  test('sender stream stops when no receiver connects', () async {
    final engine = _FakeAudioRelayEngine();
    final controller =
        AudioRelayController(
            engine: engine,
            discoveryService: _FakeDiscoveryService(),
            streamConnectionTimeout: Duration.zero,
          )
          ..role = RelayRole.sender
          ..capabilities = _supportedCapabilities;

    await controller.startSenderStream();
    await _pumpEventQueue();

    expect(controller.activity, RelayActivity.advertising);
    expect(engine.calls, ['prepareSender', 'startStream', 'stopStream']);
    expect(
      controller.noticeMessage,
      'Stopped stream after a moment without a receiver.',
    );

    controller.dispose();
  });

  test('sender stream stays active when peer metrics arrive', () async {
    final engine = _FakeAudioRelayEngine();
    final controller =
        AudioRelayController(
            engine: engine,
            discoveryService: _FakeDiscoveryService(),
            streamConnectionTimeout: const Duration(milliseconds: 20),
          )
          ..role = RelayRole.sender
          ..capabilities = _supportedCapabilities;

    await controller.startSenderStream();
    engine.metrics = const AudioRelayMetrics(peerConnected: true);
    await controller.pollMetricsForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(controller.activity, RelayActivity.streaming);
    expect(engine.calls, ['prepareSender', 'startStream']);

    controller.dispose();
  });

  test('sender cannot change receiver output backend', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..capabilities = _receiverBackendCapabilities;

    controller.updateOutputBackend(OutputAudioBackend.audioTrack);

    expect(controller.receiverOutputBackend, OutputAudioBackend.auto);
    expect(controller.profile.outputBackend, OutputAudioBackend.auto);

    controller.dispose();
  });

  test(
    'receiver output backend is applied when connecting to a sender',
    () async {
      final engine = _FakeAudioRelayEngine();
      final controller =
          AudioRelayController(
              engine: engine,
              discoveryService: _FakeDiscoveryService(),
            )
            ..role = RelayRole.receiver
            ..capabilities = _receiverBackendCapabilities;
      final device = RelayDevice(
        id: 'source-1',
        name: 'Windows source',
        host: '192.168.1.25',
        port: DiscoveryService.audioPort,
        transport: RelayTransport.wifi,
        platform: DevicePlatform.windows,
        profile: AudioPreset.balanced.profile,
        lastSeen: DateTime.now(),
      );

      controller.updateOutputBackend(OutputAudioBackend.audioTrack);
      await controller.connectToDevice(device);

      expect(controller.receiverOutputBackend, OutputAudioBackend.audioTrack);
      expect(controller.profile.outputBackend, OutputAudioBackend.audioTrack);
      expect(
        engine.profiles.single.outputBackend,
        OutputAudioBackend.audioTrack,
      );
      expect(
        engine.connectedProfiles.single.outputBackend,
        OutputAudioBackend.audioTrack,
      );

      controller.dispose();
    },
  );

  test('receiver output backend is held while streaming', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.receiver
      ..activity = RelayActivity.streaming
      ..capabilities = _receiverBackendCapabilities;

    controller.updateOutputBackend(OutputAudioBackend.audioTrack);

    expect(controller.receiverOutputBackend, OutputAudioBackend.auto);
    expect(controller.profile.outputBackend, OutputAudioBackend.auto);

    controller.dispose();
  });

  test(
    'receiver profile follows sender discovery updates while streaming',
    () async {
      final discoveryService = _FakeDiscoveryService();
      final controller =
          AudioRelayController(
              engine: _FakeAudioRelayEngine(),
              discoveryService: discoveryService,
            )
            ..role = RelayRole.receiver
            ..capabilities = _supportedCapabilities;
      final device = RelayDevice(
        id: 'source-1',
        name: 'Windows source',
        host: '192.168.1.25',
        port: DiscoveryService.audioPort,
        transport: RelayTransport.wifi,
        platform: DevicePlatform.windows,
        profile: AudioPreset.balanced.profile,
        lastSeen: DateTime.now(),
      );

      await controller.startDiscovery();
      await controller.connectToDevice(device);
      discoveryService.emit(
        device.copyWith(
          profile: AudioPreset.music.profile,
          lastSeen: DateTime.now(),
        ),
      );

      expect(controller.activity, RelayActivity.streaming);
      expect(
        controller.profile.hasSameSettings(AudioPreset.music.profile),
        true,
      );
      expect(controller.selectedDevice?.profile.sampleRate, 96000);

      controller.dispose();
    },
  );

  test('receiver profile follows active stream metrics', () async {
    final engine = _FakeAudioRelayEngine();
    final controller =
        AudioRelayController(
            engine: engine,
            discoveryService: _FakeDiscoveryService(),
          )
          ..role = RelayRole.receiver
          ..capabilities = _supportedCapabilities;
    final device = RelayDevice(
      id: 'source-1',
      name: 'Windows source',
      host: '192.168.1.25',
      port: DiscoveryService.audioPort,
      transport: RelayTransport.wifi,
      platform: DevicePlatform.windows,
      profile: AudioPreset.balanced.profile,
      lastSeen: DateTime.now(),
    );

    engine.metrics = AudioRelayMetrics(
      activeProfile: AudioPreset.music.profile,
    );
    await controller.connectToDevice(device);
    await Future<void>.delayed(const Duration(milliseconds: 550));

    expect(controller.activity, RelayActivity.streaming);
    expect(controller.profile.hasSameSettings(AudioPreset.music.profile), true);

    controller.dispose();
  });

  test('developer checks include Android native unit tests', () {
    final devCheck = File('scripts/dev_check.ps1').readAsStringSync();
    final devWorkflow = File('.github/workflows/dev.yml').readAsStringSync();

    expect(devCheck, contains('testDebugUnitTest'));
    expect(devWorkflow, contains('testDebugUnitTest'));
  });

  test('usb sender reports native usb setup failures', () async {
    final engine = _FakeAudioRelayEngine(
      prepareUsbError: PlatformException(
        code: 'native_usb',
        message: 'No Android accessory interface is available.',
      ),
    );
    final controller =
        AudioRelayController(
            engine: engine,
            discoveryService: _FakeDiscoveryService(),
          )
          ..role = RelayRole.sender
          ..capabilities = _supportedCapabilities;

    await controller.setTransport(RelayTransport.usb);
    await controller.startDiscovery();

    expect(controller.activity, RelayActivity.error);
    expect(
      controller.errorMessage,
      'No Android accessory interface is available.',
    );
    expect(engine.calls, ['prepareUsbSender']);

    controller.dispose();
  });
}

const _supportedCapabilities = PlatformAudioCapabilities(
  platform: 'test',
  canSend: true,
  canReceive: true,
  backend: 'fake',
  supportedCodecs: {AudioCodec.pcm},
  supportedOutputBackends: {OutputAudioBackend.auto},
  codecBitrateRanges: {},
);

const _androidSupportedCapabilities = PlatformAudioCapabilities(
  platform: 'android',
  canSend: true,
  canReceive: true,
  backend: 'fake',
  supportedCodecs: {AudioCodec.pcm},
  supportedOutputBackends: {OutputAudioBackend.auto},
  codecBitrateRanges: {},
);

const _receiverBackendCapabilities = PlatformAudioCapabilities(
  platform: 'test',
  canSend: true,
  canReceive: true,
  backend: 'fake',
  supportedCodecs: {AudioCodec.pcm},
  supportedOutputBackends: {
    OutputAudioBackend.auto,
    OutputAudioBackend.audioTrack,
  },
  codecBitrateRanges: {},
);

const _adaptiveCodecCapabilities = PlatformAudioCapabilities(
  platform: 'test',
  canSend: true,
  canReceive: true,
  backend: 'fake',
  supportedCodecs: {AudioCodec.pcm, AudioCodec.opus, AudioCodec.aac},
  supportedOutputBackends: {OutputAudioBackend.auto},
  codecBitrateRanges: {
    AudioCodec.opus: CodecBitrateRange(minKbps: 64, maxKbps: 256),
    AudioCodec.aac: CodecBitrateRange(minKbps: 96, maxKbps: 192),
  },
);

const _soundboardCapabilities = PlatformAudioCapabilities(
  platform: 'windows',
  canSend: true,
  canReceive: true,
  backend: 'fake',
  supportedCodecs: {AudioCodec.pcm},
  supportedOutputBackends: {OutputAudioBackend.auto},
  codecBitrateRanges: {},
  soundboardOutputDevices: [
    SoundboardOutputDevice(
      id: 'route-1',
      name: 'CABLE Input',
      isDefault: true,
      isVirtualCable: true,
    ),
  ],
  canPlaySoundEffects: true,
);

const _soundboardPhysicalOnlyCapabilities = PlatformAudioCapabilities(
  platform: 'windows',
  canSend: true,
  canReceive: true,
  backend: 'fake',
  supportedCodecs: {AudioCodec.pcm},
  supportedOutputBackends: {OutputAudioBackend.auto},
  codecBitrateRanges: {},
  soundboardOutputDevices: [
    SoundboardOutputDevice(
      id: 'speakers-1',
      name: 'Speakers (Realtek(R) Audio)',
      isDefault: true,
    ),
  ],
  canPlaySoundEffects: true,
);

const _soundboardMixedVirtualCapabilities = PlatformAudioCapabilities(
  platform: 'windows',
  canSend: true,
  canReceive: true,
  backend: 'fake',
  supportedCodecs: {AudioCodec.pcm},
  supportedOutputBackends: {OutputAudioBackend.auto},
  codecBitrateRanges: {},
  soundboardOutputDevices: [
    SoundboardOutputDevice(
      id: 'voicemeeter-1',
      name: 'Speakers (VB-Audio Voicemeeter VAIO)',
      isDefault: true,
      isVirtualCable: true,
    ),
    SoundboardOutputDevice(
      id: 'cable-2',
      name: 'CABLE Input (VB-Audio Virtual Cable)',
      isDefault: false,
      isVirtualCable: true,
    ),
    SoundboardOutputDevice(
      id: 'cable-1',
      name: 'CABLE In 16 Ch (VB-Audio Virtual Cable)',
      isDefault: false,
      isVirtualCable: true,
    ),
  ],
  canPlaySoundEffects: true,
);

AppUpdateRelease _updateRelease({
  required String tagName,
  required String assetName,
  required AppUpdateTarget target,
}) {
  return AppUpdateRelease(
    tagName: tagName,
    version: tagName.replaceFirst('v', ''),
    pageUrl: Uri.parse(
      'https://codeberg.org/SketchyLucian/audiobridge/releases/tag/$tagName',
    ),
    asset: AppUpdateAsset(
      name: assetName,
      downloadUrl: Uri.parse(
        'https://codeberg.org/SketchyLucian/audiobridge/releases/download/$tagName/$assetName',
      ),
      sizeBytes: 3,
      target: target,
    ),
  );
}

Future<void> _pumpEventQueue() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeAudioRelayEngine implements AudioRelayEngine {
  _FakeAudioRelayEngine({
    this.prepareUsbError,
    PlatformAudioCapabilities? capabilities,
    this.capabilitiesGate,
  }) : capabilities = capabilities ?? PlatformAudioCapabilities.fallback();

  final PlatformException? prepareUsbError;
  final PlatformAudioCapabilities capabilities;
  final Completer<void>? capabilitiesGate;
  final List<String> calls = [];
  final List<AudioProfile> profiles = [];
  final List<AudioProfile> startedProfiles = [];
  final List<AudioProfile> connectedProfiles = [];
  final List<String?> senderBindAddresses = [];
  final List<String> soundEffectPaths = [];
  final List<double> soundEffectVolumes = [];
  final List<SoundboardPlaybackTarget> soundEffectTargets = [];
  final List<String?> soundEffectOutputDeviceIds = [];
  final List<bool> virtualMicPassthroughEnabled = [];
  final List<String?> virtualMicPassthroughOutputDeviceIds = [];
  AudioRelayMetrics metrics = AudioRelayMetrics.empty;

  @override
  Future<void> connectToSender(RelayDevice device, AudioProfile profile) async {
    connectedProfiles.add(profile);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<PlatformAudioCapabilities> getCapabilities() async {
    await capabilitiesGate?.future;
    return capabilities;
  }

  @override
  Future<AudioRelayMetrics> getMetrics() async {
    return metrics;
  }

  @override
  Future<void> prepareReceiver(AudioProfile profile) async {
    calls.add('prepareReceiver');
    profiles.add(profile);
  }

  @override
  Future<void> prepareSender(
    AudioProfile profile, {
    String? networkBindAddress,
  }) async {
    calls.add('prepareSender');
    profiles.add(profile);
    senderBindAddresses.add(networkBindAddress);
  }

  @override
  Future<void> prepareUsbSender(AudioProfile profile) async {
    calls.add('prepareUsbSender');
    profiles.add(profile);
    final error = prepareUsbError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> prepareUsbReceiver(AudioProfile profile) async {
    calls.add('prepareUsbReceiver');
    profiles.add(profile);
  }

  @override
  Future<void> setMuted(bool value) async {}

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> playSoundEffect({
    required String path,
    required double volume,
    required SoundboardPlaybackTarget target,
    String? outputDeviceId,
  }) async {
    calls.add('playSoundEffect');
    soundEffectPaths.add(path);
    soundEffectVolumes.add(volume);
    soundEffectTargets.add(target);
    soundEffectOutputDeviceIds.add(outputDeviceId);
  }

  @override
  Future<void> configureVirtualMicPassthrough({
    required bool enabled,
    String? outputDeviceId,
  }) async {
    virtualMicPassthroughEnabled.add(enabled);
    virtualMicPassthroughOutputDeviceIds.add(outputDeviceId);
  }

  @override
  Future<void> stopSoundEffects() async {
    calls.add('stopSoundEffects');
  }

  @override
  Future<void> startStream(AudioProfile profile) async {
    calls.add('startStream');
    startedProfiles.add(profile);
  }

  @override
  Future<void> stopStream() async {
    calls.add('stopStream');
  }
}

class _FakeAudioProfileStore implements AudioProfileStore {
  _FakeAudioProfileStore({this.savedProfile, this.saveError});

  AudioProfile? savedProfile;
  Object? saveError;

  @override
  Future<AudioProfile?> loadCustomProfile() async {
    return savedProfile;
  }

  @override
  Future<void> saveCustomProfile(AudioProfile profile) async {
    final error = saveError;
    if (error != null) {
      throw error;
    }
    savedProfile = profile;
  }
}

class _FakeAudioRelayPreferencesStore implements AudioRelayPreferencesStore {
  _FakeAudioRelayPreferencesStore({this.savedPreferences});

  AudioRelayPreferences? savedPreferences;

  @override
  Future<AudioRelayPreferences?> loadPreferences() async {
    return savedPreferences;
  }

  @override
  Future<void> savePreferences(AudioRelayPreferences preferences) async {
    savedPreferences = preferences;
  }
}

class _FakeDiscoveryService extends DiscoveryService {
  final List<RelayDevice> advertisedDevices = [];
  final List<AudioProfile> advertisedProfiles = [];
  final List<DiscoveryNetworkScope> advertisedScopes = [];
  final List<DiscoveryNetworkScope> scanningScopes = [];
  RelayDeviceSeen? onDeviceSeen;
  bool scanningStarted = false;

  @override
  Future<String> localIPv4Address({
    DiscoveryNetworkScope scope = DiscoveryNetworkScope.all,
  }) async {
    return switch (scope) {
      DiscoveryNetworkScope.usbTethering => '192.168.11.87',
      DiscoveryNetworkScope.wifi => '192.168.1.130',
      DiscoveryNetworkScope.all => '192.168.1.130',
    };
  }

  @override
  Future<void> startAdvertising(
    RelayDevice device, {
    DiscoveryNetworkScope scope = DiscoveryNetworkScope.all,
  }) async {
    advertisedDevices.add(device);
    advertisedProfiles.add(device.profile);
    advertisedScopes.add(scope);
  }

  @override
  Future<void> startScanning(
    RelayDeviceSeen onDeviceSeen, {
    DiscoveryNetworkScope scope = DiscoveryNetworkScope.all,
  }) async {
    scanningStarted = true;
    scanningScopes.add(scope);
    this.onDeviceSeen = onDeviceSeen;
  }

  @override
  Future<void> stopScanning() async {
    scanningStarted = false;
    onDeviceSeen = null;
  }

  @override
  Future<void> dispose() async {}

  void emit(RelayDevice device) {
    onDeviceSeen?.call(device);
  }
}

class _FakeUpdateService implements AppUpdateService {
  _FakeUpdateService({this.release, this.downloadedFile});

  final AppUpdateRelease? release;
  final File? downloadedFile;
  int checkCount = 0;

  @override
  Future<AppUpdateCheckResult> checkForUpdate({
    required String currentVersion,
    required AppUpdateTarget target,
  }) async {
    checkCount += 1;
    return AppUpdateCheckResult(
      currentVersion: currentVersion,
      target: target,
      release: release,
    );
  }

  @override
  Future<File> downloadUpdate(
    AppUpdateRelease release, {
    ValueChanged<double?>? onProgress,
  }) async {
    onProgress?.call(1);
    return downloadedFile ?? File('');
  }
}

class _FakeUpdateInstaller implements UpdateInstaller {
  final List<String> openedUrls = [];
  final List<String> installedPackages = [];

  @override
  Future<void> openReleasePage(Uri url) async {
    openedUrls.add(url.toString());
  }

  @override
  Future<void> installPackage(File packageFile) async {
    installedPackages.add(packageFile.path);
  }
}
