# AudioBridge Virtual Microphone

This folder tracks the Windows driver path for making AudioBridge appear in
Discord, Zoom, and games as a real microphone device.

## Status

This is an experimental driver track, not a finished signed driver. The Flutter
app can already send soundboard audio to a render endpoint. A call app can only
select that audio as a microphone when Windows has a matching capture endpoint.
Creating that capture endpoint requires a Windows audio driver.

End-user setup is included in the Windows MSI as an `AudioBridge Virtual Mic
Setup` Start menu shortcut. That setup helper detects supported virtual cable
drivers such as VB-CABLE or Voicemeeter and opens the official VB-CABLE setup
page when no compatible cable is present. The app-owned AudioBridge driver work
below remains separate until it is complete and production-signed.

## Target Design

The practical design is a small virtual audio cable:

- Render endpoint: `AudioBridge Cable Input`
- Capture endpoint: `AudioBridge Microphone`
- AudioBridge writes soundboard PCM to the render endpoint.
- The driver copies render PCM into an internal ring buffer.
- Discord selects `AudioBridge Microphone` and reads from the capture endpoint.

This is intentionally different from trying to write into
`Microphone (Realtek(R) Audio)`. Windows does not expose a supported API for a
normal app to inject audio into another physical microphone endpoint.

## Microsoft Starting Point

Use Microsoft's SYSVAD sample as the base. It is the official virtual audio
device driver sample and shows how to expose WDM audio devices without hardware.

Relevant Microsoft references:

- SYSVAD sample:
  https://learn.microsoft.com/en-us/samples/microsoft/windows-driver-samples/sysvad-virtual-audio-device-driver-sample/
- Universal Windows audio drivers:
  https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/audio-universal-drivers

## Prerequisites

Install these before building the driver:

- Visual Studio or Visual Studio Build Tools with C++ build tools
- Windows SDK
- Windows Driver Kit (WDK)
- Git

Check this machine:

```powershell
.\scripts\check_virtual_mic_prereqs.ps1
```

If `inf2cat`, `WindowsKernelModeDriver10.0`, or
`WindowsApplicationForDrivers10.0` is missing, the Windows Driver Kit is not
fully installed. Run this from an elevated PowerShell session:

```powershell
.\scripts\install_virtual_mic_prereqs_admin.ps1
```

The installer may require a visible UAC prompt. If it exits with `0x80070642`,
Windows cancelled the elevation/install UI. Re-run the script in an elevated
terminal and accept the prompt.

## Fetch And Build The Base Driver

Fetch only the SYSVAD part of the Windows Driver Samples repository:

```powershell
.\scripts\setup_virtual_mic_driver.ps1
```

Build it:

```powershell
.\scripts\build_virtual_mic_driver.ps1 -Configuration Debug -Platform x64
```

The build script reports the package folder that contains the `.sys`, `.inf`,
and `.cat` files.

## Manual Test Install

Driver testing requires an elevated shell and test signing. On a test machine,
run this as Administrator:

```powershell
bcdedit /set TESTSIGNING ON
```

Reboot. If BitLocker or Secure Boot blocks this, follow Microsoft driver-testing
guidance before changing boot settings.

After building the package, install the INF from an elevated shell:

```powershell
pnputil /add-driver .\tabletaudiosample.inf /install
```

The unmodified SYSVAD sample appears as a Microsoft sample virtual audio device.
That only proves the driver toolchain and install path. The next work is to
rename the endpoints and add the render-to-capture ring buffer.

## Current Local State

The SYSVAD source has been fetched to
`third_party/windows-driver-samples/audio/sysvad`. On this machine, MSBuild
currently fails because the WDK driver toolsets are missing:

- `WindowsKernelModeDriver10.0`
- `WindowsApplicationForDrivers10.0`
- `inf2cat.exe`

That is an environment blocker, not a Flutter app blocker.

## Next Driver Work

1. Reduce SYSVAD to one render endpoint and one capture endpoint.
2. Rename endpoints to `AudioBridge Cable Input` and `AudioBridge Microphone`.
3. Add a lock-free or guarded PCM ring buffer shared by the render and capture
   miniports.
4. In the render path, write incoming PCM frames into the ring buffer.
5. In the capture path, read frames from the ring buffer and output silence on
   underrun.
6. Package the signed driver separately from the Flutter MSI.
7. Update AudioBridge to auto-select `AudioBridge Cable Input` when the driver
   is installed.

Production distribution will require real driver signing. Test-signed drivers
are for local development only.
