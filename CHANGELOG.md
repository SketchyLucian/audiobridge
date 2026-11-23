# Changelog

## 1.6.0 - 2026-11-23

- Upgraded Windows WASAPI capture and playback to event-driven scheduling
  (`AUDCLNT_STREAMFLAGS_EVENTCALLBACK` with automatic fallback) and active
  1 ms timer resolution, eliminating 1 ms polling overhead and reducing jitter.
- Rewrote the Windows packetizer to use a head-offset buffer and zero-allocation
  codec encode buffers, synchronized profile updates across threads, and capped
  diagnostic USB log files at 64 KB.
- Added a Windows Sender capture output-device selector ("System default" or
  any active Windows audio output, with live switching and device refresh) so
  users can capture a specific device without changing the system default.
- Implemented native Android AAudio playback (`OutputAudioBackend.oboe` on
  Android 8.0+) with automatic AudioTrack fallback, plus Android `AudioFocus`
  handling (ducking on notifications, muting during calls).
- Enabled R8 code/resource shrinking and focused release ABIs (`arm64-v8a`,
  `armeabi-v7a`) to cut Android release APK size significantly.
- Registered an automatic Windows Firewall UDP rule in the MSI installer,
  removed the duplicate `third_party/opus-1.6.1.tar.gz` archive (~10.5 MB),
  scoped Flutter 450 ms telemetry rebuilds to live metric widgets, and modularized
  the Windows codec and Flutter UI code.

## 1.5.0 - 2026-11-23

- Open-sourced AudioBridge under the GNU General Public License v3.0 and moved
  public releases and in-app update checks directly to `SketchyLucian/audiobridge`.
- Unbundled the third-party VB-CABLE installer from the Windows MSI and replaced
  the post-install prompt with a direct link to VB-Audio's download page for
  optional Soundboard call-mic routing.
- Automatically followed Windows default audio output device changes and
  recovered from invalidated endpoints in both loopback capture and receiver
  playback, preventing silent stalls and reconnect crashes.
- Added a Soundboard audio-device refresh button, clearer missing-file errors,
  and reset the physical microphone bridge toggle when stopping.

## 1.4.10 - 2026-08-14

- Rolled back the 1.4.9 playback drift correction because its packet-level
  timing adjustments could introduce audible jitter across all presets.
- Restored the known-good 1.4.8 adaptive buffering behavior while a
  continuous-stream replacement is validated separately.

## 1.4.9 - 2026-08-14

- Prevented steady sender and receiver clock differences from being mistaken
  for worsening network jitter in the Balanced adaptive buffer.
- Smoothed Android and Windows playback queue recovery so excess latency drains
  gradually instead of causing periodic whole-packet drops and audio stutter.

## 1.4.8 - 2026-08-13

- Prevented idle VB-CABLE soundboard routing from continuously forwarding the
  physical microphone and causing speaker echo.
- Added an explicit, session-only physical microphone bridge control with a
  headphone warning. The bridge is off by default.

## 1.4.7 - 2026-08-12

- Connected to an available receiver source as soon as its device row is
  selected, without requiring a separate Connect action.

## 1.4.6 - 2026-08-11

- Added an opt-in post-install prompt that verifies and installs the bundled
  VB-CABLE donationware package for the Windows soundboard.
- Added an in-app call microphone setup action when the Windows soundboard
  cannot find a virtual audio cable.
- Fixed the bundled virtual microphone setup helper when no compatible driver
  is installed.
- Moved the private source repository and public update release feed to GitHub.
- Replaced the unavailable Android signing key. Existing Android users must
  uninstall an earlier AudioBridge version before installing 1.4.6.

## 1.4.5 - 2026-07-30

- Kept Android media playback active with local silent frames when the Windows
  source stops producing audio.
- Marked receiver output as background media so screen-off power handling does
  not suspend it during silence.
- Added foreground-service lock diagnostics and a clearer Low Power Standby
  warning.

## 1.4.4 - 2026-07-30

- Kept Android receiver playback active while the source is silent and its
  heartbeat remains connected.
- Added a persistent Silent connection timeout setting. It defaults to Never,
  with optional limits from 30 seconds to 30 minutes.
- Improved Android foreground-service handling and added a warning when Low
  Power Standby can block screen-off network access.

## 1.4.3 - 2026-07-29

- Kept the Android Wi-Fi radio awake for active network audio streams so
  playback and reconnection continue when the screen is off or the app is in
  the background.

## 1.4.2 - 2026-07-23

- Moved update checks to the public `audiobridge-releases` repository so
  Windows clients can discover and download releases without authentication.

## 1.4.1 - 2026-07-22

- Kept native USB sessions connected during silent Windows playback by sending
  heartbeat frames independently of captured audio.

## 1.4.0 - 2026-07-16

- Added a Linux desktop target for Wi-Fi PCM relay using default ALSA
  capture/playback endpoints, including PipeWire and PulseAudio ALSA
  compatibility support.
- Added Linux UDP receiver subscriptions, session heartbeats, live queue and
  signal metrics, and a Wi-Fi-only transport capability.
- Added Linux build coverage in CI and a portable Linux bundle packaging script.

## 1.3.0 - 2026-07-03

- Added session-aware connection heartbeat so silence no longer looks like a disconnect.
- Added automatic reconnect with backoff, discovery refresh, and network-interface refresh.
- Preserved the selected receiver source while reconnecting and reattached when the source is rediscovered with a new address.
- Rejected stale or wrong-session packets after the new transport handshake.
- Fixed Android OTA permission flow so the APK installer opens after install permission is granted.

## 1.2.2 - 2026-07-03

- Kept receiver sessions alive during silence with a 10-minute no-audio timeout.
- Removed stale advertised sources when senders stop broadcasting.
- Stopped receiver playback cleanly when the selected source disappears.

## 1.2.1 - 2026-07-02

- Fixed Windows update installs so AudioBridge relaunches after the MSI closes the running app.
- Fixed Android update installs when the downloaded APK is stored in app-private temp storage outside the FileProvider cache path.

## 1.2.0 - 2026-07-02

- Added automatic idle stop behavior so scans and sender streams stop when no peer connects.
- Added durable app preferences for role, transport, audio settings, volume, mute, receiver backend, and soundboard setup.
- Added mono/stereo channel selection across Flutter, Windows, and Android audio paths.
- Moved the soundboard to its own tab and made receiver adaptive buffering easier to understand in the audio settings.
- Improved Codeberg update checks with clearer current/latest version and release package details.
