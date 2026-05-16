import 'dart:io';

import 'package:audiorelay_clone/features/audio_relay/application/audio_relay_controller.dart';
import 'package:audiorelay_clone/features/audio_relay/data/audio_profile_store.dart';
import 'package:audiorelay_clone/features/audio_relay/data/discovery_service.dart';
import 'package:audiorelay_clone/features/audio_relay/data/native_audio_engine.dart';
import 'package:audiorelay_clone/features/audio_relay/domain/audio_relay_models.dart';
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
    );

    controller.updatePreset(AudioPreset.gaming);
    controller.updatePlaybackBuffer(22);
    controller.saveCustomPreset();
    controller.updateAdaptiveBufferCap(54);

    expect(controller.selectedPreset, AudioPreset.custom);
    expect(controller.profile.mode, AudioPreset.custom);
    expect(controller.profile.playbackBufferMs, 22);
    expect(controller.profile.adaptiveBufferCapMs, 54);
    expect(store.savedProfile?.mode, AudioPreset.custom);
    expect(store.savedProfile?.playbackBufferMs, 22);

    controller.updatePreset(AudioPreset.music);
    controller.updatePreset(AudioPreset.custom);

    expect(controller.profile.mode, AudioPreset.custom);
    expect(controller.profile.playbackBufferMs, 22);
    expect(controller.profile.adaptiveBufferCapMs, 54);

    controller.dispose();
  });

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
    );

    await controller.initialize();
    controller.updatePreset(AudioPreset.custom);

    expect(controller.profile.mode, AudioPreset.custom);
    expect(controller.profile.playbackBufferMs, 72);
    expect(controller.profile.adaptiveBufferCapMs, 144);

    controller.dispose();
  });

  test('sender settings remain editable while streaming', () {
    final controller = AudioRelayController(engine: _FakeAudioRelayEngine())
      ..role = RelayRole.sender
      ..activity = RelayActivity.streaming;

    expect(controller.canEditAudioSettings, true);

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
      engine.profiles.single.hasSameSettings(AudioProfile.usbLowLatency),
      true,
    );
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
        AudioProfile.usbTetheringLowLatency,
      ),
      true,
    );
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

class _FakeAudioRelayEngine implements AudioRelayEngine {
  _FakeAudioRelayEngine({this.prepareUsbError});

  final PlatformException? prepareUsbError;
  final List<String> calls = [];
  final List<AudioProfile> profiles = [];
  final List<AudioProfile> connectedProfiles = [];
  final List<String?> senderBindAddresses = [];
  AudioRelayMetrics metrics = AudioRelayMetrics.empty;

  @override
  Future<void> connectToSender(RelayDevice device, AudioProfile profile) async {
    connectedProfiles.add(profile);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<PlatformAudioCapabilities> getCapabilities() async {
    return PlatformAudioCapabilities.fallback();
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
  Future<void> startStream(AudioProfile profile) async {
    calls.add('startStream');
  }

  @override
  Future<void> stopStream() async {
    calls.add('stopStream');
  }
}

class _FakeAudioProfileStore implements AudioProfileStore {
  _FakeAudioProfileStore({this.savedProfile});

  AudioProfile? savedProfile;

  @override
  Future<AudioProfile?> loadCustomProfile() async {
    return savedProfile;
  }

  @override
  Future<void> saveCustomProfile(AudioProfile profile) async {
    savedProfile = profile;
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
