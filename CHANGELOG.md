# Changelog

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
