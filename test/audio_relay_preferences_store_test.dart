import 'package:audiorelay_clone/features/audio_relay/data/audio_relay_preferences_store.dart';
import 'package:audiorelay_clone/features/audio_relay/domain/audio_relay_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preferences snapshot round-trips every durable setting', () {
    const preferences = AudioRelayPreferences(
      role: RelayRole.receiver,
      transport: RelayTransport.usbTethering,
      profile: AudioProfile(
        mode: AudioPreset.custom,
        codec: AudioCodec.opus,
        sampleRate: 48000,
        bitrateKbps: 128,
        adaptiveBitrate: true,
        latencyMs: 32,
        captureBufferMs: 14,
        playbackBufferMs: 32,
        packetTimeMs: 2,
        channels: 1,
        receiverAdaptiveBuffer: false,
        adaptiveBufferCapMs: 96,
      ),
      receiverOutputBackend: OutputAudioBackend.audioTrack,
      volume: 0.44,
      muted: true,
      soundboardPaths: [r'C:\sounds\one.wav', r'C:\sounds\two.mp3'],
      selectedSoundboardPath: r'C:\sounds\two.mp3',
      soundboardTarget: SoundboardPlaybackTarget.stream,
      selectedSoundboardOutputDeviceId: 'cable-1',
      soundboardVolume: 0.31,
      silentConnectionTimeoutSeconds: 300,
    );

    final restored = AudioRelayPreferences.fromMap(preferences.toMap());

    expect(restored.role, preferences.role);
    expect(restored.transport, preferences.transport);
    expect(restored.profile.hasSameSettings(preferences.profile), true);
    expect(restored.receiverOutputBackend, preferences.receiverOutputBackend);
    expect(restored.volume, preferences.volume);
    expect(restored.muted, preferences.muted);
    expect(restored.soundboardPaths, preferences.soundboardPaths);
    expect(restored.selectedSoundboardPath, preferences.selectedSoundboardPath);
    expect(restored.soundboardTarget, preferences.soundboardTarget);
    expect(
      restored.selectedSoundboardOutputDeviceId,
      preferences.selectedSoundboardOutputDeviceId,
    );
    expect(restored.soundboardVolume, preferences.soundboardVolume);
    expect(
      restored.silentConnectionTimeoutSeconds,
      preferences.silentConnectionTimeoutSeconds,
    );
  });

  test('preferences parser clamps values and ignores invalid paths', () {
    final restored = AudioRelayPreferences.fromMap({
      'volume': 4,
      'soundboardVolume': -2,
      'soundboardPaths': ['one.wav', '', 'one.wav', null],
      'silentConnectionTimeoutSeconds': -1,
    });

    expect(restored.volume, 1);
    expect(restored.soundboardVolume, 0);
    expect(restored.soundboardPaths, ['one.wav']);
    expect(restored.silentConnectionTimeoutSeconds, isNull);
  });
}
