# Changelog

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
