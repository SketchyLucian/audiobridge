# ADR 0001: Use A Windows Audio Driver For The Virtual Microphone

Status: Accepted

## Context

AudioBridge needs soundboard audio to be selectable as a microphone in call
apps. Discord and similar apps enumerate Windows capture endpoints. A Flutter
desktop app can render audio to playback endpoints, but it cannot register a
new system microphone or inject audio into an existing physical microphone.

Microsoft's SYSVAD sample is the official starting point for a virtual WDM
audio driver. It provides a driver framework for virtual audio devices without
hardware dependencies.

## Decision

AudioBridge will treat an app-owned virtual microphone as a Windows driver
project, separate from the Flutter app. The target driver shape is a virtual
audio cable with one render endpoint and one capture endpoint:

- `AudioBridge Cable Input`
- `AudioBridge Microphone`

The app writes soundboard audio to the render endpoint. The driver makes that
audio available through the capture endpoint so call apps can select it as a
microphone.

## Consequences

- The Flutter app remains a user-mode app and does not impersonate a physical
  microphone.
- Local development requires Visual Studio, Windows SDK, WDK, test signing, and
  an elevated install flow.
- Shipping requires production driver signing and a separate installer path.
- Until the driver is complete, AudioBridge should continue to support existing
  virtual-cable drivers such as VB-CABLE and Voicemeeter.

## Alternatives Considered

- Write directly into `Microphone (Realtek(R) Audio)`: rejected because Windows
  does not expose a supported user-mode injection API for physical capture
  endpoints.
- Keep only third-party virtual cables: useful today, but it does not give
  AudioBridge its own microphone device.
- Build the driver directly into the Flutter app: rejected because driver
  install, signing, and runtime ownership are separate OS concerns.

## References

- https://learn.microsoft.com/en-us/samples/microsoft/windows-driver-samples/sysvad-virtual-audio-device-driver-sample/
- https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/audio-universal-drivers
