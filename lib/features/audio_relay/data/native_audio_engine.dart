import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/audio_relay_models.dart';

class PlatformAudioCapabilities {
  const PlatformAudioCapabilities({
    required this.platform,
    required this.canSend,
    required this.canReceive,
    required this.backend,
    required this.supportedCodecs,
    required this.supportedOutputBackends,
    required this.codecBitrateRanges,
    this.supportedTransports = const {
      RelayTransport.wifi,
      RelayTransport.usbTethering,
      RelayTransport.usb,
    },
    this.soundboardOutputDevices = const [],
    this.canPlaySoundEffects = false,
    this.detail,
  });

  final String platform;
  final bool canSend;
  final bool canReceive;
  final String backend;
  final Set<AudioCodec> supportedCodecs;
  final Set<OutputAudioBackend> supportedOutputBackends;
  final Map<AudioCodec, CodecBitrateRange> codecBitrateRanges;
  final Set<RelayTransport> supportedTransports;
  final List<SoundboardOutputDevice> soundboardOutputDevices;
  final bool canPlaySoundEffects;
  final String? detail;

  factory PlatformAudioCapabilities.fromMap(Map<String, Object?> payload) {
    final codecNames = payload['supportedCodecs'];
    final outputBackendNames = payload['supportedOutputBackends'];
    final bitrateRanges = payload['codecBitrateRanges'];
    final transportNames = payload['supportedTransports'];
    final soundboardOutputDevices = payload['soundboardOutputDevices'];

    return PlatformAudioCapabilities(
      platform: payload['platform']?.toString() ?? _platformName(),
      canSend: payload['canSend'] == true,
      canReceive: payload['canReceive'] == true,
      backend: payload['backend']?.toString() ?? 'method-channel',
      supportedCodecs: _readSupportedCodecs(codecNames),
      supportedOutputBackends: _readSupportedOutputBackends(outputBackendNames),
      codecBitrateRanges: _readBitrateRanges(bitrateRanges),
      supportedTransports: _readSupportedTransports(transportNames),
      soundboardOutputDevices: _readSoundboardOutputDevices(
        soundboardOutputDevices,
      ),
      canPlaySoundEffects: payload['canPlaySoundEffects'] == true,
      detail: payload['detail']?.toString(),
    );
  }

  factory PlatformAudioCapabilities.fallback({String? detail}) {
    final isWindows = Platform.isWindows;
    final isAndroid = Platform.isAndroid;
    final isLinux = Platform.isLinux;

    return PlatformAudioCapabilities(
      platform: _platformName(),
      canSend: isWindows || isAndroid || (!isWindows && !isAndroid),
      canReceive: isAndroid || (!isWindows && !isAndroid),
      backend: 'flutter-scaffold',
      supportedCodecs: const {AudioCodec.pcm},
      supportedOutputBackends: {
        OutputAudioBackend.auto,
        if (isWindows) OutputAudioBackend.wasapiShared,
        if (isAndroid) OutputAudioBackend.audioTrack,
      },
      codecBitrateRanges: const {},
      supportedTransports: isLinux
          ? const {RelayTransport.wifi}
          : Set<RelayTransport>.unmodifiable(RelayTransport.values),
      soundboardOutputDevices: const [],
      canPlaySoundEffects: false,
      detail: detail ?? 'Native audio backend is not installed yet.',
    );
  }

  bool supportsCodec(AudioCodec codec) {
    return supportedCodecs.contains(codec);
  }

  bool supportsOutputBackend(OutputAudioBackend backend) {
    return supportedOutputBackends.contains(backend);
  }

  static Set<AudioCodec> _readSupportedCodecs(Object? value) {
    if (value is! List) {
      return const {AudioCodec.pcm};
    }
    final codecs = value
        .map((item) => AudioCodec.fromName(item?.toString()))
        .toSet();
    return codecs.isEmpty ? const {AudioCodec.pcm} : codecs;
  }

  static Set<OutputAudioBackend> _readSupportedOutputBackends(Object? value) {
    if (value is! List) {
      return const {OutputAudioBackend.auto};
    }
    final backends = value
        .map((item) => OutputAudioBackend.fromName(item?.toString()))
        .toSet();
    return backends.isEmpty ? const {OutputAudioBackend.auto} : backends;
  }

  static Map<AudioCodec, CodecBitrateRange> _readBitrateRanges(Object? value) {
    if (value is! Map) {
      return const {};
    }

    return {
      for (final entry in value.entries)
        AudioCodec.fromName(entry.key?.toString()): CodecBitrateRange.fromMap(
          entry.value,
        ),
    };
  }

  static Set<RelayTransport> _readSupportedTransports(Object? value) {
    if (value is! List) {
      return Set<RelayTransport>.unmodifiable(RelayTransport.values);
    }
    final transports = value
        .map((item) => RelayTransport.tryParse(item?.toString()))
        .whereType<RelayTransport>()
        .toSet();
    return transports.isEmpty
        ? Set<RelayTransport>.unmodifiable(RelayTransport.values)
        : Set<RelayTransport>.unmodifiable(transports);
  }

  static List<SoundboardOutputDevice> _readSoundboardOutputDevices(
    Object? value,
  ) {
    if (value is! List) {
      return const [];
    }

    return [
      for (final item in value)
        if (item is Map)
          SoundboardOutputDevice.fromMap(item.cast<Object?, Object?>()),
    ];
  }

  static String _platformName() {
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    return Platform.operatingSystem;
  }
}

class CodecBitrateRange {
  const CodecBitrateRange({required this.minKbps, required this.maxKbps});

  final int minKbps;
  final int maxKbps;

  factory CodecBitrateRange.fromMap(Object? payload) {
    if (payload is! Map) {
      return const CodecBitrateRange(minKbps: 0, maxKbps: 0);
    }
    return CodecBitrateRange(
      minKbps: _readInt(payload['minKbps']),
      maxKbps: _readInt(payload['maxKbps']),
    );
  }

  static int _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class AudioRelayMetrics {
  const AudioRelayMetrics({
    this.audioLatencyMs,
    this.outputLatencyMs,
    this.networkLatencyMs,
    this.signalLevel,
    this.queuedFrames,
    this.bufferSizeFrames,
    this.targetBufferFrames,
    this.adaptivePlaybackBufferMs,
    this.adaptiveMaxPlaybackBufferMs,
    this.adaptiveLimitReached,
    this.adaptiveUnderrunsInWindow,
    this.adaptiveUnderrunsInBurst,
    this.adaptiveLowQueueSamples,
    this.playbackQueueFillPercent,
    this.underrunCount,
    this.droppedPacketCount,
    this.lostPacketCount,
    this.trimCount,
    this.activeProfile,
    this.remotePlatform,
    this.remoteSupportedCodecs = const {},
    this.peerConnected,
    this.sourceAudioActive,
  });

  final double? audioLatencyMs;
  final double? outputLatencyMs;
  final double? networkLatencyMs;
  final double? signalLevel;
  final int? queuedFrames;
  final int? bufferSizeFrames;
  final int? targetBufferFrames;
  final int? adaptivePlaybackBufferMs;
  final int? adaptiveMaxPlaybackBufferMs;
  final bool? adaptiveLimitReached;
  final int? adaptiveUnderrunsInWindow;
  final int? adaptiveUnderrunsInBurst;
  final int? adaptiveLowQueueSamples;
  final int? playbackQueueFillPercent;
  final int? underrunCount;
  final int? droppedPacketCount;
  final int? lostPacketCount;
  final int? trimCount;
  final AudioProfile? activeProfile;
  final String? remotePlatform;
  final Set<AudioCodec> remoteSupportedCodecs;
  final bool? peerConnected;
  final bool? sourceAudioActive;

  double? get effectiveLatencyMs => audioLatencyMs ?? outputLatencyMs;

  static const empty = AudioRelayMetrics();

  factory AudioRelayMetrics.fromMap(Map<String, Object?> payload) {
    final activeProfilePayload = payload['activeProfile'];
    return AudioRelayMetrics(
      audioLatencyMs: _readDouble(payload['audioLatencyMs']),
      outputLatencyMs: _readDouble(payload['outputLatencyMs']),
      networkLatencyMs: _readDouble(payload['networkLatencyMs']),
      signalLevel: _readDouble(payload['signalLevel']),
      queuedFrames: _readInt(payload['queuedFrames']),
      bufferSizeFrames: _readInt(payload['bufferSizeFrames']),
      targetBufferFrames: _readInt(payload['targetBufferFrames']),
      adaptivePlaybackBufferMs: _readInt(payload['adaptivePlaybackBufferMs']),
      adaptiveMaxPlaybackBufferMs: _readInt(
        payload['adaptiveMaxPlaybackBufferMs'],
      ),
      adaptiveLimitReached: _readBool(payload['adaptiveLimitReached']),
      adaptiveUnderrunsInWindow: _readInt(payload['adaptiveUnderrunsInWindow']),
      adaptiveUnderrunsInBurst: _readInt(payload['adaptiveUnderrunsInBurst']),
      adaptiveLowQueueSamples: _readInt(payload['adaptiveLowQueueSamples']),
      playbackQueueFillPercent: _readInt(payload['playbackQueueFillPercent']),
      underrunCount: _readInt(payload['underrunCount']),
      droppedPacketCount: _readInt(payload['droppedPacketCount']),
      lostPacketCount: _readInt(payload['lostPacketCount']),
      trimCount: _readInt(payload['trimCount']),
      activeProfile: activeProfilePayload is Map
          ? AudioProfile.fromMap(activeProfilePayload.cast<Object?, Object?>())
          : null,
      remotePlatform: payload['remotePlatform']?.toString(),
      remoteSupportedCodecs: _readCodecSet(payload['remoteSupportedCodecs']),
      peerConnected: _readBool(payload['peerConnected']),
      sourceAudioActive: _readBool(payload['sourceAudioActive']),
    );
  }

  static double? _readDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static int? _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static bool? _readBool(Object? value) {
    if (value is bool) {
      return value;
    }
    return switch (value?.toString().toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => null,
    };
  }

  static Set<AudioCodec> _readCodecSet(Object? value) {
    if (value is! List) {
      return const {};
    }
    return value
        .map((item) => AudioCodec.fromName(item?.toString()))
        .where((codec) => codec != AudioCodec.auto)
        .toSet();
  }
}

abstract interface class AudioRelayEngine {
  Future<PlatformAudioCapabilities> getCapabilities();

  Future<AudioRelayMetrics> getMetrics();

  Future<void> prepareSender(
    AudioProfile profile, {
    String? networkBindAddress,
    RelayTransport transport = RelayTransport.wifi,
  });

  Future<void> prepareUsbSender(AudioProfile profile);

  Future<void> prepareUsbReceiver(AudioProfile profile);

  Future<void> prepareReceiver(AudioProfile profile);

  Future<void> connectToSender(RelayDevice device, AudioProfile profile);

  Future<void> startStream(AudioProfile profile);

  Future<void> stopStream();

  Future<void> setVolume(double value);

  Future<void> setMuted(bool value);

  Future<void> playSoundEffect({
    required String path,
    required double volume,
    required SoundboardPlaybackTarget target,
    String? outputDeviceId,
  });

  Future<void> configureVirtualMicPassthrough({
    required bool enabled,
    String? outputDeviceId,
  });

  Future<void> launchVirtualMicSetup();

  Future<void> stopSoundEffects();

  Future<void> disconnect();
}

class MethodChannelAudioRelayEngine implements AudioRelayEngine {
  const MethodChannelAudioRelayEngine();

  static const MethodChannel _channel = MethodChannel(
    'audio_bridge/native_engine',
  );

  @override
  Future<PlatformAudioCapabilities> getCapabilities() async {
    try {
      final payload = await _channel.invokeMapMethod<String, Object?>(
        'getCapabilities',
      );
      return PlatformAudioCapabilities.fromMap(payload ?? {});
    } on MissingPluginException {
      return PlatformAudioCapabilities.fallback();
    } on PlatformException catch (error) {
      return PlatformAudioCapabilities.fallback(detail: error.message);
    }
  }

  @override
  Future<AudioRelayMetrics> getMetrics() async {
    try {
      final payload = await _channel.invokeMapMethod<String, Object?>(
        'getMetrics',
      );
      return AudioRelayMetrics.fromMap(payload ?? {});
    } on MissingPluginException {
      return AudioRelayMetrics.empty;
    } on PlatformException {
      return AudioRelayMetrics.empty;
    }
  }

  @override
  Future<void> prepareSender(
    AudioProfile profile, {
    String? networkBindAddress,
    RelayTransport transport = RelayTransport.wifi,
  }) {
    final networkBindKey = networkBindAddress == null
        ? null
        : 'networkBindAddress';
    final payload = {
      ...profile.toMap(),
      'transport': transport.name,
      ?networkBindKey: networkBindAddress,
    };
    return _invoke('prepareSender', payload);
  }

  @override
  Future<void> prepareUsbSender(AudioProfile profile) {
    return _invoke('prepareUsbSender', profile.toMap());
  }

  @override
  Future<void> prepareUsbReceiver(AudioProfile profile) {
    return _invoke('prepareUsbReceiver', profile.toMap());
  }

  @override
  Future<void> prepareReceiver(AudioProfile profile) {
    return _invoke('prepareReceiver', profile.toMap());
  }

  @override
  Future<void> connectToSender(RelayDevice device, AudioProfile profile) {
    return _invoke('connectToSender', {
      'device': {
        'id': device.id,
        'name': device.name,
        'host': device.host,
        'port': device.port,
        'transport': device.transport.name,
        'platform': device.platform.name,
      },
      'profile': profile.toMap(),
    });
  }

  @override
  Future<void> startStream(AudioProfile profile) {
    return _invoke('startStream', profile.toMap());
  }

  @override
  Future<void> stopStream() {
    return _invoke('stopStream');
  }

  @override
  Future<void> setVolume(double value) {
    return _invoke('setVolume', {'value': value});
  }

  @override
  Future<void> setMuted(bool value) {
    return _invoke('setMuted', {'value': value});
  }

  @override
  Future<void> playSoundEffect({
    required String path,
    required double volume,
    required SoundboardPlaybackTarget target,
    String? outputDeviceId,
  }) {
    return _invoke('playSoundEffect', {
      'path': path,
      'volume': volume,
      'target': target.methodValue,
      'outputDeviceId': ?outputDeviceId,
    });
  }

  @override
  Future<void> configureVirtualMicPassthrough({
    required bool enabled,
    String? outputDeviceId,
  }) {
    return _invoke('configureVirtualMicPassthrough', {
      'enabled': enabled,
      'outputDeviceId': ?outputDeviceId,
    });
  }

  @override
  Future<void> launchVirtualMicSetup() {
    return _invoke('launchVirtualMicSetup');
  }

  @override
  Future<void> stopSoundEffects() {
    return _invoke('stopSoundEffects');
  }

  @override
  Future<void> disconnect() {
    return _invoke('disconnect');
  }

  Future<void> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      return;
    }
  }
}
