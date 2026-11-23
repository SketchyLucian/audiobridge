enum RelayRole {
  sender,
  receiver;

  String get label {
    return switch (this) {
      RelayRole.sender => 'Sender',
      RelayRole.receiver => 'Receiver',
    };
  }
}

enum RelayTransport {
  wifi,
  usbTethering,
  usb;

  String get label {
    return switch (this) {
      RelayTransport.wifi => 'Wi-Fi',
      RelayTransport.usbTethering => 'USB tethering',
      RelayTransport.usb => 'Native USB',
    };
  }

  static RelayTransport fromName(String? value) {
    final normalized = value?.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');
    return switch (normalized) {
      'usbtethering' || 'tethering' => RelayTransport.usbTethering,
      'usb' => RelayTransport.usb,
      _ => RelayTransport.wifi,
    };
  }

  static RelayTransport? tryParse(String? value) {
    return switch (value?.toLowerCase().replaceAll(RegExp(r'[-_\\s]'), '')) {
      'wifi' || 'wireless' || 'lan' => RelayTransport.wifi,
      'usbtethering' || 'tethering' => RelayTransport.usbTethering,
      'usb' || 'nativeusb' => RelayTransport.usb,
      _ => null,
    };
  }
}

enum RelayActivity {
  idle,
  advertising,
  scanning,
  connecting,
  streaming,
  reconnecting,
  error;

  String get label {
    return switch (this) {
      RelayActivity.idle => 'Idle',
      RelayActivity.advertising => 'Hosting',
      RelayActivity.scanning => 'Scanning',
      RelayActivity.connecting => 'Connecting',
      RelayActivity.streaming => 'Streaming',
      RelayActivity.reconnecting => 'Reconnecting',
      RelayActivity.error => 'Needs attention',
    };
  }
}

enum AudioCodec {
  auto,
  pcm,
  opus,
  aac,
  flac,
  mp3,
  vorbis,
  alac,
  lc3,
  g711MuLaw,
  g711ALaw,
  imaAdpcm;

  String get label {
    return switch (this) {
      AudioCodec.auto => 'Adaptive',
      AudioCodec.pcm => 'PCM',
      AudioCodec.opus => 'Opus',
      AudioCodec.aac => 'AAC',
      AudioCodec.flac => 'FLAC',
      AudioCodec.mp3 => 'MP3',
      AudioCodec.vorbis => 'Vorbis',
      AudioCodec.alac => 'ALAC',
      AudioCodec.lc3 => 'LC3',
      AudioCodec.g711MuLaw => 'G.711 mu-law',
      AudioCodec.g711ALaw => 'G.711 A-law',
      AudioCodec.imaAdpcm => 'IMA ADPCM',
    };
  }

  bool get isImplemented {
    return switch (this) {
      AudioCodec.auto ||
      AudioCodec.pcm ||
      AudioCodec.opus ||
      AudioCodec.aac ||
      AudioCodec.g711MuLaw ||
      AudioCodec.g711ALaw ||
      AudioCodec.imaAdpcm => true,
      _ => false,
    };
  }

  String get availabilityLabel {
    return this == AudioCodec.auto
        ? 'Adaptive'
        : isImplemented
        ? 'Native required'
        : 'Encoder pending';
  }

  int get packetId {
    return switch (this) {
      AudioCodec.auto => -1,
      AudioCodec.pcm => 0,
      AudioCodec.opus => 1,
      AudioCodec.aac => 2,
      AudioCodec.flac => 3,
      AudioCodec.mp3 => 4,
      AudioCodec.vorbis => 5,
      AudioCodec.alac => 6,
      AudioCodec.lc3 => 7,
      AudioCodec.g711MuLaw => 8,
      AudioCodec.g711ALaw => 9,
      AudioCodec.imaAdpcm => 10,
    };
  }

  static AudioCodec fromName(String? value) {
    final normalized = value?.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');
    if (normalized == 'adaptive' || normalized == 'automatic') {
      return AudioCodec.auto;
    }
    if (normalized == 'aaclc' || normalized == 'acc') {
      return AudioCodec.aac;
    }

    return AudioCodec.values.firstWhere(
      (candidate) => candidate.name.toLowerCase() == normalized,
      orElse: () => AudioCodec.pcm,
    );
  }

  static AudioCodec fromPacketId(int value) {
    return AudioCodec.values.firstWhere(
      (candidate) =>
          candidate != AudioCodec.auto && candidate.packetId == value,
      orElse: () => AudioCodec.pcm,
    );
  }
}

enum OutputAudioBackend {
  auto,
  audioTrack,
  oboe,
  wasapiShared,
  wasapiExclusive;

  String get label {
    return switch (this) {
      OutputAudioBackend.auto => 'Auto',
      OutputAudioBackend.audioTrack => 'AudioTrack',
      OutputAudioBackend.oboe => 'Oboe / AAudio',
      OutputAudioBackend.wasapiShared => 'WASAPI shared',
      OutputAudioBackend.wasapiExclusive => 'WASAPI exclusive',
    };
  }

  bool get isImplemented {
    return switch (this) {
      OutputAudioBackend.auto ||
      OutputAudioBackend.audioTrack ||
      OutputAudioBackend.oboe ||
      OutputAudioBackend.wasapiShared => true,
      OutputAudioBackend.wasapiExclusive => false,
    };
  }

  String get availabilityLabel {
    return isImplemented ? 'Available' : 'Backend pending';
  }

  static OutputAudioBackend fromName(String? value) {
    final normalized = value?.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');
    return OutputAudioBackend.values.firstWhere(
      (candidate) =>
          candidate.name.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '') ==
          normalized,
      orElse: () => OutputAudioBackend.auto,
    );
  }
}

enum SoundboardPlaybackTarget {
  stream,
  micRoute;

  String get label {
    return switch (this) {
      SoundboardPlaybackTarget.stream => 'Stream',
      SoundboardPlaybackTarget.micRoute => 'Mic + speaker',
    };
  }

  String get methodValue {
    return switch (this) {
      SoundboardPlaybackTarget.stream => 'stream',
      SoundboardPlaybackTarget.micRoute => 'micRoute',
    };
  }
}

enum AudioPreset {
  gaming,
  balanced,
  music,
  custom;

  String get label {
    return switch (this) {
      AudioPreset.gaming => 'Gaming',
      AudioPreset.balanced => 'Balanced',
      AudioPreset.music => 'Music',
      AudioPreset.custom => 'Custom',
    };
  }

  AudioProfile get profile {
    return switch (this) {
      AudioPreset.gaming => const AudioProfile(
        mode: AudioPreset.gaming,
        codec: AudioCodec.auto,
        sampleRate: 48000,
        bitrateKbps: 1536,
        latencyMs: 18,
        captureBufferMs: 10,
        playbackBufferMs: 18,
        packetTimeMs: 1,
        channels: 2,
      ),
      AudioPreset.balanced => const AudioProfile(
        mode: AudioPreset.balanced,
        codec: AudioCodec.pcm,
        sampleRate: 48000,
        bitrateKbps: 1536,
        latencyMs: 45,
        captureBufferMs: 30,
        playbackBufferMs: 45,
        packetTimeMs: 3,
        channels: 2,
      ),
      AudioPreset.music => const AudioProfile(
        mode: AudioPreset.music,
        codec: AudioCodec.pcm,
        sampleRate: 96000,
        bitrateKbps: 3072,
        latencyMs: 320,
        captureBufferMs: 160,
        playbackBufferMs: 320,
        packetTimeMs: 12,
        channels: 2,
      ),
      AudioPreset.custom => const AudioProfile(
        mode: AudioPreset.custom,
        codec: AudioCodec.pcm,
        sampleRate: 48000,
        bitrateKbps: 1536,
        latencyMs: 45,
        captureBufferMs: 30,
        playbackBufferMs: 45,
        packetTimeMs: 3,
        channels: 2,
        adaptiveBufferCapMs: 240,
      ),
    };
  }

  static AudioPreset? match(AudioProfile profile) {
    for (final preset in AudioPreset.values) {
      if (preset.profile.hasSameStreamSettings(profile)) {
        return preset;
      }
    }
    return null;
  }

  static AudioPreset fromName(String? value, {required AudioPreset fallback}) {
    final normalized = value?.toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');
    return switch (normalized) {
      'gaming' || 'game' || 'lowlatency' => AudioPreset.gaming,
      'balanced' || 'balance' => AudioPreset.balanced,
      'music' || 'stable' || 'stability' => AudioPreset.music,
      'custom' || 'user' || 'manual' => AudioPreset.custom,
      _ => fallback,
    };
  }
}

enum DevicePlatform {
  windows,
  android,
  unknown;

  String get label {
    return switch (this) {
      DevicePlatform.windows => 'Windows',
      DevicePlatform.android => 'Android',
      DevicePlatform.unknown => 'Unknown',
    };
  }

  static DevicePlatform fromName(String? value) {
    return switch (value?.toLowerCase()) {
      'windows' => DevicePlatform.windows,
      'android' => DevicePlatform.android,
      _ => DevicePlatform.unknown,
    };
  }
}

class AudioProfile {
  static const minBufferMs = 5;
  static const maxBufferMs = 500;
  static const minPacketTimeMs = 1;
  static const maxPacketTimeMs = 12;

  static const usbLowLatency = AudioProfile(
    mode: AudioPreset.gaming,
    codec: AudioCodec.auto,
    sampleRate: 48000,
    bitrateKbps: 1536,
    latencyMs: 6,
    captureBufferMs: 6,
    playbackBufferMs: 6,
    packetTimeMs: 1,
    channels: 2,
  );

  static const usbTetheringLowLatency = AudioProfile(
    mode: AudioPreset.gaming,
    codec: AudioCodec.auto,
    sampleRate: 48000,
    bitrateKbps: 1536,
    latencyMs: 24,
    captureBufferMs: 12,
    playbackBufferMs: 24,
    packetTimeMs: 2,
    channels: 2,
  );

  const AudioProfile({
    this.mode = AudioPreset.balanced,
    this.codec = AudioCodec.pcm,
    this.outputBackend = OutputAudioBackend.auto,
    this.sampleRate = 48000,
    this.bitrateKbps = 192,
    this.adaptiveSampleRate = false,
    this.adaptiveBitrate = false,
    this.latencyMs = 35,
    this.captureBufferMs = 35,
    this.playbackBufferMs = 35,
    this.packetTimeMs = 3,
    this.channels = 2,
    this.receiverAdaptiveBuffer = true,
    this.adaptiveBufferCapMs = 0,
  });

  final AudioPreset mode;
  final AudioCodec codec;
  final OutputAudioBackend outputBackend;
  final int sampleRate;
  final int bitrateKbps;
  final bool adaptiveSampleRate;
  final bool adaptiveBitrate;
  final int latencyMs;
  final int captureBufferMs;
  final int playbackBufferMs;
  final int packetTimeMs;
  final int channels;
  final bool receiverAdaptiveBuffer;
  final int adaptiveBufferCapMs;

  int get effectiveBitrateKbps {
    return switch (codec) {
      AudioCodec.auto => bitrateKbps,
      AudioCodec.pcm => (sampleRate * channels * 16 / 1000).round(),
      AudioCodec.opus => bitrateKbps.clamp(64, 256).toInt(),
      AudioCodec.aac => bitrateKbps.clamp(96, 192).toInt(),
      AudioCodec.g711MuLaw ||
      AudioCodec.g711ALaw => (sampleRate * channels * 8 / 1000).round(),
      AudioCodec.imaAdpcm => (sampleRate * channels * 4 / 1000).round(),
      _ => bitrateKbps,
    };
  }

  bool hasSameSettings(AudioProfile other) {
    return hasSameStreamSettings(other) &&
        adaptiveSampleRate == other.adaptiveSampleRate &&
        adaptiveBitrate == other.adaptiveBitrate &&
        receiverAdaptiveBuffer == other.receiverAdaptiveBuffer;
  }

  bool hasSameStreamSettings(AudioProfile other) {
    return mode == other.mode &&
        codec == other.codec &&
        outputBackend == other.outputBackend &&
        sampleRate == other.sampleRate &&
        effectiveBitrateKbps == other.effectiveBitrateKbps &&
        latencyMs == other.latencyMs &&
        captureBufferMs == other.captureBufferMs &&
        playbackBufferMs == other.playbackBufferMs &&
        packetTimeMs == other.packetTimeMs &&
        channels == other.channels &&
        adaptiveBufferCapMs == other.adaptiveBufferCapMs;
  }

  AudioProfile copyWith({
    AudioPreset? mode,
    AudioCodec? codec,
    OutputAudioBackend? outputBackend,
    int? sampleRate,
    int? bitrateKbps,
    bool? adaptiveSampleRate,
    bool? adaptiveBitrate,
    int? latencyMs,
    int? captureBufferMs,
    int? playbackBufferMs,
    int? packetTimeMs,
    int? channels,
    bool? receiverAdaptiveBuffer,
    int? adaptiveBufferCapMs,
  }) {
    return AudioProfile(
      mode: mode ?? this.mode,
      codec: codec ?? this.codec,
      outputBackend: outputBackend ?? this.outputBackend,
      sampleRate: sampleRate ?? this.sampleRate,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      adaptiveSampleRate: adaptiveSampleRate ?? this.adaptiveSampleRate,
      adaptiveBitrate: adaptiveBitrate ?? this.adaptiveBitrate,
      latencyMs: latencyMs ?? this.latencyMs,
      captureBufferMs: captureBufferMs ?? this.captureBufferMs,
      playbackBufferMs: playbackBufferMs ?? this.playbackBufferMs,
      packetTimeMs: packetTimeMs ?? this.packetTimeMs,
      channels: channels ?? this.channels,
      receiverAdaptiveBuffer:
          receiverAdaptiveBuffer ?? this.receiverAdaptiveBuffer,
      adaptiveBufferCapMs: adaptiveBufferCapMs ?? this.adaptiveBufferCapMs,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'mode': mode.name,
      'codec': codec.name,
      'outputBackend': outputBackend.name,
      'sampleRate': sampleRate,
      'bitrateKbps': effectiveBitrateKbps,
      'adaptiveSampleRate': adaptiveSampleRate,
      'adaptiveBitrate': adaptiveBitrate,
      'latencyMs': latencyMs,
      'captureBufferMs': captureBufferMs,
      'playbackBufferMs': playbackBufferMs,
      'packetTimeMs': packetTimeMs,
      'channels': channels,
      'receiverAdaptiveBuffer': receiverAdaptiveBuffer,
      'adaptiveBufferCapMs': adaptiveBufferCapMs,
    };
  }

  factory AudioProfile.fromMap(Map<Object?, Object?> payload) {
    final codec = AudioCodec.fromName(payload['codec']?.toString());
    final outputBackend = OutputAudioBackend.fromName(
      payload['outputBackend']?.toString(),
    );
    final mode = AudioPreset.fromName(
      payload['mode']?.toString(),
      fallback: _modeFallbackFor(payload),
    );

    return AudioProfile(
      mode: mode,
      codec: codec,
      outputBackend: outputBackend,
      sampleRate: _readInt(payload['sampleRate'], fallback: 48000),
      bitrateKbps: _readInt(payload['bitrateKbps'], fallback: 192),
      adaptiveSampleRate: _readBool(
        payload['adaptiveSampleRate'],
        fallback: false,
      ),
      adaptiveBitrate: _readBool(payload['adaptiveBitrate'], fallback: false),
      latencyMs: _readInt(payload['latencyMs'], fallback: 35),
      captureBufferMs: _readInt(
        payload['captureBufferMs'],
        fallback: _readInt(payload['latencyMs'], fallback: 35),
      ),
      playbackBufferMs: _readInt(
        payload['playbackBufferMs'],
        fallback: _readInt(payload['latencyMs'], fallback: 35),
      ),
      packetTimeMs: _readInt(payload['packetTimeMs'], fallback: 3),
      channels: _readInt(payload['channels'], fallback: 2).clamp(1, 2).toInt(),
      receiverAdaptiveBuffer: _readBool(
        payload['receiverAdaptiveBuffer'],
        fallback: true,
      ),
      adaptiveBufferCapMs: _readInt(
        payload['adaptiveBufferCapMs'],
        fallback: 0,
      ),
    );
  }

  static int _readInt(Object? value, {required int fallback}) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static bool _readBool(Object? value, {required bool fallback}) {
    if (value is bool) {
      return value;
    }
    return switch (value?.toString().toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => fallback,
    };
  }

  static AudioPreset _modeFallbackFor(Map<Object?, Object?> payload) {
    final latencyMs = _readInt(payload['latencyMs'], fallback: 35);
    final captureBufferMs = _readInt(
      payload['captureBufferMs'],
      fallback: latencyMs,
    );
    final playbackBufferMs = _readInt(
      payload['playbackBufferMs'],
      fallback: latencyMs,
    );
    final packetTimeMs = _readInt(payload['packetTimeMs'], fallback: 3);
    final sampleRate = _readInt(payload['sampleRate'], fallback: 48000);

    if (playbackBufferMs <= 28 || packetTimeMs <= 2) {
      return AudioPreset.gaming;
    }
    if (sampleRate >= 96000 ||
        playbackBufferMs >= 120 ||
        captureBufferMs >= 120 ||
        packetTimeMs >= 10) {
      return AudioPreset.music;
    }
    return AudioPreset.balanced;
  }
}

class RelayDevice {
  const RelayDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.transport,
    required this.platform,
    required this.profile,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final RelayTransport transport;
  final DevicePlatform platform;
  final AudioProfile profile;
  final DateTime lastSeen;

  RelayDevice copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    RelayTransport? transport,
    DevicePlatform? platform,
    AudioProfile? profile,
    DateTime? lastSeen,
  }) {
    return RelayDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      transport: transport ?? this.transport,
      platform: platform ?? this.platform,
      profile: profile ?? this.profile,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, Object?> toDiscoveryMap() {
    return {
      'type': 'audiobridge.source',
      'version': 1,
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'transport': transport.name,
      'platform': platform.name,
      'profile': profile.toMap(),
    };
  }

  static RelayDevice? fromDiscoveryMap(
    Map<String, Object?> payload, {
    required String sourceHost,
  }) {
    if (payload['type'] != 'audiobridge.source') {
      return null;
    }

    final profilePayload = payload['profile'];
    final profile = profilePayload is Map
        ? AudioProfile.fromMap(profilePayload.cast<Object?, Object?>())
        : const AudioProfile();

    final transport = RelayTransport.fromName(payload['transport']?.toString());
    final advertisedHost = _readString(payload['host'], fallback: sourceHost);
    final host = transport == RelayTransport.usb ? advertisedHost : sourceHost;

    return RelayDevice(
      id: _readString(payload['id'], fallback: sourceHost),
      name: _readString(payload['name'], fallback: 'Audio source'),
      host: host,
      port: _readInt(payload['port'], fallback: 47885),
      transport: transport,
      platform: DevicePlatform.fromName(payload['platform']?.toString()),
      profile: profile,
      lastSeen: DateTime.now(),
    );
  }

  static String _readString(Object? value, {required String fallback}) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? fallback : text;
  }

  static int _readInt(Object? value, {required int fallback}) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

class SoundPlaybackItem {
  const SoundPlaybackItem({
    required this.id,
    required this.name,
    required this.path,
  });

  final String id;
  final String name;
  final String path;
}

class SoundboardOutputDevice {
  const SoundboardOutputDevice({
    required this.id,
    required this.name,
    required this.isDefault,
    this.isVirtualCable = false,
  });

  final String id;
  final String name;
  final bool isDefault;
  final bool isVirtualCable;

  factory SoundboardOutputDevice.fromMap(Map<Object?, Object?> payload) {
    final id = payload['id']?.toString() ?? '';
    final name = payload['name']?.toString() ?? id;
    final displayName = name.isEmpty ? 'Audio device' : name;
    return SoundboardOutputDevice(
      id: id,
      name: displayName,
      isDefault: payload['isDefault'] == true,
      isVirtualCable:
          payload['isVirtualCable'] == true ||
          _looksLikeVirtualCable('$displayName $id'),
    );
  }

  static bool _looksLikeVirtualCable(String value) {
    final label = value.toLowerCase();
    return label.contains('vb-audio') ||
        label.contains('virtual audio') ||
        label.contains('virtual cable') ||
        label.contains('voicemeeter') ||
        label.contains('cable input') ||
        label.contains('cable-a input') ||
        label.contains('cable-b input') ||
        label.contains('line 1') && label.contains('virtual');
  }
}
