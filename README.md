# AudioBridge

AudioBridge is a Flutter frontend for a LAN audio relay app targeting Windows,
Android, and Linux. The current build includes the product UI, connection state,
UDP source discovery, USB tethering, USB cable mode, Simple/Advanced audio
settings, live latency metrics, and native method-channel seams for platform
audio engines.

## Current Scope

- Windows sender and receiver mode UI
- Android Wi-Fi sender and receiver mode UI
- Linux Wi-Fi sender and receiver mode with default ALSA capture/playback and
  PCM audio
- Codeberg release checks with assisted APK and MSI installation
- UDP LAN discovery on port `47884`
- Audio streaming on port `47885`
- Session-aware heartbeat, stale-packet rejection, and automatic reconnect with
  discovery and network-interface refresh
- USB tethering mode that uses the phone's USB network interface with UDP
  discovery/audio
- Native USB cable audio streaming over Android Open Accessory bulk endpoints
- Native USB low-latency profile: 48 kHz stereo, 6 ms sender buffer, adaptive
  receiver buffer starting at 6 ms, and 1 ms packets
- USB tethering low-latency profile: 48 kHz stereo, 12 ms sender buffer,
  24 ms receiver buffer, and 2 ms packets
- Sender-side audio modes for Gaming, Balanced, Music, and saved Custom.
  Modes travel with the stream and affect receiver adaptive-buffer limits, not
  just default slider values.
- Adaptive sender tuning that starts from the Gaming profile, watches receiver
  underruns, queue pressure, packet loss/drop counters, trims, and latency
  metrics, then changes receiver buffer and packet time in real time without
  changing the active audio format
- Advanced sender-side settings for sender capture buffer, receiver playback
  buffer, packet time, active codec path, mute, and volume. Receivers apply the
  profile advertised by the sender.
- Android `AudioTrack` playback backend for UDP audio packets
- Android `AudioRecord` microphone capture backend for UDP audio packets
- Windows WASAPI loopback capture backend for UDP audio packets
- Windows sender soundboard panel that can queue local audio files into the
  active outgoing stream or feed an installed virtual microphone cable such as
  `CABLE Input`.

The native audio capture/playback engines are isolated behind
`audio_bridge/native_engine`. The working native codec paths are PCM, Opus,
AAC-LC, G.711 mu-law, G.711 A-law, and IMA ADPCM over UDP, USB tethering, or
native USB accessory bulk transfer. Higher-complexity codec options remain in the Flutter model
until native encoder/decoder integration is added.

## Project Layout

- `lib/app`: app shell and theme
- `lib/features/audio_relay/domain`: relay models and profile data
- `lib/features/audio_relay/data`: UDP discovery and native engine adapter
- `lib/features/audio_relay/application`: session controller
- `lib/features/audio_relay/presentation`: Flutter dashboard UI
- `android/app/src/main/kotlin`: Android method-channel entry point
- `windows/runner`: Windows method-channel entry point
- `linux/runner`: Linux method-channel entry point

## Run

```powershell
flutter pub get
flutter run -d windows
```

For Android, connect a device or start an emulator:

```powershell
flutter devices
flutter run -d <android-device-id>
```

For Linux Wi-Fi relay, install the standard Flutter Linux desktop build
dependencies and ensure `libasound.so.2` is available. AudioBridge opens the
default ALSA capture and playback endpoints; PipeWire and PulseAudio work when
they provide the ALSA default device.

```bash
flutter pub get
flutter run -d linux
```

The Linux port supports Wi-Fi UDP relay with PCM only. USB tethering, native
USB accessory mode, virtual microphone routing, soundboard output, and
in-app update installation are not available on Linux.

## Dev Workflow

Run the local developer check before opening a pull request:

```powershell
.\scripts\dev_check.ps1
```

For faster local iteration, skip a platform compile check when it is not
needed:

```powershell
.\scripts\dev_check.ps1 -SkipWindowsBuild
.\scripts\dev_check.ps1 -SkipAndroidBuild
```

Close any running `AudioBridge.exe` before the Windows build. The linker cannot
overwrite the debug executable while the app is still running.

## Windows MSI

The Windows app can be packaged as an MSI with WiX Toolset SDK 5. The packaging
script builds the Flutter Windows release bundle, then wraps
`build/windows/x64/runner/Release` into an MSI that installs AudioBridge under
Program Files and adds a Start menu shortcut.

Prerequisite: install the .NET SDK 6 or newer so the WiX SDK project can be
restored and built.

```powershell
.\scripts\package_windows_msi.ps1
```

The MSI is written to `build/installer/AudioBridge-<version>-x64.msi`.

## Publishing releases

Public releases are published to the `audiobridge-releases` Codeberg
repository. A release is kept as a draft unless both of these signed artifacts
exist and pass validation:

- `AudioBridge-<version>-x64.msi`
- `AudioBridge-<version>-android.apk`

The tag-triggered release workflow builds both platforms and calls
`scripts/publish_codeberg_release.ps1`. Configure its Android signing secrets
and `CODEBERG_RELEASE_TOKEN`; missing credentials or either missing artifact
fails the workflow without publishing a partial release.

The MSI also installs an `AudioBridge Virtual Mic Setup` Start menu shortcut.
Run it after installation to check for a supported virtual cable driver and, if
needed, open the official VB-CABLE setup page. Install the VB-CABLE driver as
Administrator and reboot Windows before selecting `CABLE Input` in AudioBridge
and `CABLE Output` in the call app.

For USB tethering, enable USB tethering on Android, keep the device attached,
and select `USB tether` in both apps. The sender and receiver still use UDP
discovery and UDP audio, but over the tethered USB network interface instead of
Wi-Fi.

For native USB cable audio between Windows and a physical Android device, keep
the device attached, select `Native USB` on both apps, choose the sender and
receiver roles, then start audio. On Android, approve the AudioBridge accessory
prompt. Wi-Fi mode still uses LAN discovery and UDP audio. Windows may need the
Android accessory interface bound to the WinUSB driver before native USB can
open.

For call-app soundboard use on Windows, install or enable a virtual microphone
driver such as VB-CABLE or Voicemeeter. Windows does not allow a normal app to
write into a physical microphone like `Microphone (Realtek(R) Audio)`. Select
the virtual cable playback side such as `CABLE Input` as the Soundboard
`Virtual mic` feed, then select the matching recording side such as
`CABLE Output` as the microphone inside Discord, Zoom, or the game voice chat.
The in-repo path for building an AudioBridge-owned virtual microphone driver is
documented in `windows/virtual_mic/README.md`. That driver path requires the
Windows Driver Kit driver toolsets and driver signing; it is separate from the
normal Flutter debug run.

## Native Engine Contract

Flutter calls the `audio_bridge/native_engine` method channel:

- `getCapabilities`
- `getMetrics`
- `prepareSender`
- `prepareUsbSender`
- `prepareUsbReceiver`
- `prepareReceiver`
- `connectToSender`
- `startStream`
- `stopStream`
- `setVolume`
- `setMuted`
- `playSoundEffect`
- `stopSoundEffects`
- `disconnect`
- `openExternalUrl`
- `installUpdatePackage`

Implemented behind that channel:

- Windows: WASAPI loopback capture, soundboard file decode/mix via Media
  Foundation, optional soundboard render to a selected virtual-mic cable feed,
  PCM16 conversion, PCM/Opus/AAC-LC/G.711/IMA ADPCM encoding, receiver
  playback, UDP packet streaming, USB tethering via the normal UDP path, and
  Android Open Accessory USB bulk streaming in sender or receiver role.
- Android: microphone capture sender over Wi-Fi/USB tethering, receiver
  subscription, UDP packet receive loop, adaptive `AudioTrack` playback,
  PCM/G.711/IMA ADPCM encoding and decoding, USB tethering via the normal UDP
  path, native USB accessory sender/receiver loops, mute, and volume.
- Gaming profile: responsiveness/stability tuning, smaller UDP packets, Windows
  MMCSS capture priority, Android low-latency `AudioTrack`, non-blocking
  writes, and live Android output-buffer latency reporting.
- Sender metrics: Android includes estimated audio latency, playback-buffer
  latency, network latency, and drop/loss counters in its subscribe heartbeat
  so the Windows sender can show send-to-play latency while streaming.
- Audio latency metric: v3 audio packets carry sender monotonic timestamps and
  echoed receiver timing probes. Android estimates one-way sender-send to
  receiver-playback latency from those probes plus the current `AudioTrack`
  playback queue. The UI falls back to playback-buffer latency until the
  end-to-end estimate is available.
- Advanced transport controls: the sender controls the receiver playback
  buffer and UDP packet time. PCM, Opus, AAC-LC, G.711 mu-law, G.711 A-law, and
  IMA ADPCM are implemented; FLAC, MP3, Vorbis, ALAC, and LC3 are visible as
  unavailable codec paths until native encoders/decoders are added.
- Tight Wi-Fi transport: low-delay UDP socket options, smaller kernel socket
  queues, faster receiver heartbeats, 1 ms gaming packets, and receiver-side
  stale-audio drop/trim logic to keep playback from drifting behind.
- Tight USB tethering transport: wired-network discovery, UDP audio over the
  phone's tether interface, and a lower-latency default profile than Wi-Fi.
- Tight native USB transport: USB bulk packet framing, lower Windows capture
  minimums, zero-copy Android PCM writes for normal playback, and receiver-side
  adaptive buffering that raises only after underrun bursts or sustained low
  queue pressure, with low-latency profiles capped before they drift into
  high-delay playback.
- Linux: default ALSA microphone capture and speaker playback, PCM over Wi-Fi
  UDP, receiver subscription/heartbeat support, and live queue, signal, and
  drop metrics. PipeWire and PulseAudio are used through their ALSA
  compatibility layer when configured as the default device.

Remaining production work:

- Jitter buffer and packet-loss handling.
- Native encoders/decoders for FLAC, MP3, Vorbis, ALAC, and LC3.
- Android audio focus and foreground-service handling.
- Windows firewall guidance and explicit output-device selection.
