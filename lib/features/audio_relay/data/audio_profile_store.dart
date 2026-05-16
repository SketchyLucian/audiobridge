import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/audio_relay_models.dart';

abstract interface class AudioProfileStore {
  Future<AudioProfile?> loadCustomProfile();

  Future<void> saveCustomProfile(AudioProfile profile);
}

class SharedPreferencesAudioProfileStore implements AudioProfileStore {
  const SharedPreferencesAudioProfileStore();

  static const _customProfileKey = 'audioRelay.customProfile.v1';

  @override
  Future<AudioProfile?> loadCustomProfile() async {
    final preferences = await SharedPreferences.getInstance();
    final rawProfile = preferences.getString(_customProfileKey);
    if (rawProfile == null || rawProfile.isEmpty) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(rawProfile);
    } on FormatException {
      return null;
    }

    if (decoded is! Map) {
      return null;
    }
    return AudioProfile.fromMap(
      decoded.cast<Object?, Object?>(),
    ).copyWith(mode: AudioPreset.custom);
  }

  @override
  Future<void> saveCustomProfile(AudioProfile profile) async {
    final preferences = await SharedPreferences.getInstance();
    final payload = jsonEncode(
      profile.copyWith(mode: AudioPreset.custom).toMap(),
    );
    await preferences.setString(_customProfileKey, payload);
  }
}
