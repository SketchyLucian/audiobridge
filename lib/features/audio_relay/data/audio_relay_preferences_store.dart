import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/audio_relay_models.dart';

class AudioRelayPreferences {
  const AudioRelayPreferences({
    required this.role,
    required this.transport,
    required this.profile,
    required this.receiverOutputBackend,
    required this.volume,
    required this.muted,
    required this.soundboardPaths,
    required this.soundboardTarget,
    required this.soundboardVolume,
    this.silentConnectionTimeoutSeconds,
    this.selectedSoundboardPath,
    this.selectedSoundboardOutputDeviceId,
    this.selectedCaptureOutputDeviceId,
  });

  final RelayRole role;
  final RelayTransport transport;
  final AudioProfile profile;
  final OutputAudioBackend receiverOutputBackend;
  final double volume;
  final bool muted;
  final List<String> soundboardPaths;
  final String? selectedSoundboardPath;
  final SoundboardPlaybackTarget soundboardTarget;
  final String? selectedSoundboardOutputDeviceId;
  final String? selectedCaptureOutputDeviceId;
  final double soundboardVolume;
  final int? silentConnectionTimeoutSeconds;

  Map<String, Object?> toMap() {
    return {
      'version': 2,
      'role': role.name,
      'transport': transport.name,
      'profile': profile.toMap(),
      'receiverOutputBackend': receiverOutputBackend.name,
      'volume': volume,
      'muted': muted,
      'soundboardPaths': soundboardPaths,
      'selectedSoundboardPath': selectedSoundboardPath,
      'soundboardTarget': soundboardTarget.name,
      'selectedSoundboardOutputDeviceId': selectedSoundboardOutputDeviceId,
      'selectedCaptureOutputDeviceId': selectedCaptureOutputDeviceId,
      'soundboardVolume': soundboardVolume,
      'silentConnectionTimeoutSeconds': silentConnectionTimeoutSeconds,
    };
  }

  factory AudioRelayPreferences.fromMap(Map<Object?, Object?> map) {
    final profilePayload = map['profile'];
    final soundboardPaths = map['soundboardPaths'];

    return AudioRelayPreferences(
      role: _enumByName(
        RelayRole.values,
        map['role'],
        fallback: RelayRole.sender,
      ),
      transport: RelayTransport.fromName(map['transport']?.toString()),
      profile: profilePayload is Map
          ? AudioProfile.fromMap(profilePayload.cast<Object?, Object?>())
          : AudioPreset.balanced.profile,
      receiverOutputBackend: OutputAudioBackend.fromName(
        map['receiverOutputBackend']?.toString(),
      ),
      volume: _readUnitValue(map['volume'], fallback: 0.86),
      muted: _readBool(map['muted'], fallback: false),
      soundboardPaths: soundboardPaths is List
          ? soundboardPaths
                .map((path) => path?.toString().trim() ?? '')
                .where((path) => path.isNotEmpty)
                .toSet()
                .toList(growable: false)
          : const [],
      selectedSoundboardPath: _readOptionalString(
        map['selectedSoundboardPath'],
      ),
      soundboardTarget: _enumByName(
        SoundboardPlaybackTarget.values,
        map['soundboardTarget'],
        fallback: SoundboardPlaybackTarget.micRoute,
      ),
      selectedSoundboardOutputDeviceId: _readOptionalString(
        map['selectedSoundboardOutputDeviceId'],
      ),
      selectedCaptureOutputDeviceId: _readOptionalString(
        map['selectedCaptureOutputDeviceId'],
      ),
      soundboardVolume: _readUnitValue(map['soundboardVolume'], fallback: 0.82),
      silentConnectionTimeoutSeconds: _readPositiveInt(
        map['silentConnectionTimeoutSeconds'],
      ),
    );
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? value, {
    required T fallback,
  }) {
    final name = value?.toString();
    return values.where((candidate) => candidate.name == name).firstOrNull ??
        fallback;
  }

  static double _readUnitValue(Object? value, {required double fallback}) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return (parsed ?? fallback).clamp(0, 1).toDouble();
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

  static String? _readOptionalString(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _readPositiveInt(Object? value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }
}

abstract interface class AudioRelayPreferencesStore {
  Future<AudioRelayPreferences?> loadPreferences();

  Future<void> savePreferences(AudioRelayPreferences preferences);
}

class SharedPreferencesAudioRelayPreferencesStore
    implements AudioRelayPreferencesStore {
  const SharedPreferencesAudioRelayPreferencesStore();

  static const _preferencesKey = 'audioRelay.preferences.v1';

  @override
  Future<AudioRelayPreferences?> loadPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    final rawPreferences = preferences.getString(_preferencesKey);
    if (rawPreferences == null || rawPreferences.isEmpty) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(rawPreferences);
    } on FormatException {
      return null;
    }

    if (decoded is! Map) {
      return null;
    }
    return AudioRelayPreferences.fromMap(decoded.cast<Object?, Object?>());
  }

  @override
  Future<void> savePreferences(AudioRelayPreferences preferences) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.setString(
      _preferencesKey,
      jsonEncode(preferences.toMap()),
    );
  }
}
