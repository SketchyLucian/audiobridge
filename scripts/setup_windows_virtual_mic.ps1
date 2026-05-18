[CmdletBinding()]
param(
    [switch] $OpenDownloadPage,
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$downloadUrl = 'https://vb-audio.com/Cable/'
$knownVirtualMicTokens = @(
    'audiobridge microphone',
    'audiobridge cable',
    'vb-audio',
    'vb cable',
    'vb-cable',
    'virtual audio cable',
    'virtual cable',
    'voicemeeter',
    'cable input',
    'cable output'
)

function Test-Windows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Test-KnownVirtualMicLabel {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $label = $Value.ToLowerInvariant()
    foreach ($token in $knownVirtualMicTokens) {
        if ($label.Contains($token)) {
            return $true
        }
    }

    return $false
}

function New-DetectedDevice {
    param(
        [string] $Kind,
        [string] $Name,
        [string] $Id,
        [string] $Status
    )

    [pscustomobject]@{
        kind = $Kind
        name = $Name
        id = $Id
        status = $Status
    }
}

function Get-PnpMediaDevices {
    $getPnpDevice = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    if ($null -eq $getPnpDevice) {
        return @()
    }

    try {
        return @(
            Get-PnpDevice -Class MEDIA -ErrorAction Stop |
                ForEach-Object {
                    New-DetectedDevice `
                        -Kind 'pnp-media' `
                        -Name ([string] $_.FriendlyName) `
                        -Id ([string] $_.InstanceId) `
                        -Status ([string] $_.Status)
                }
        )
    } catch {
        return @()
    }
}

function Get-RegistryAudioEndpoints {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
    )

    $devices = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $kind = if ($root.EndsWith('\Render')) { 'render-endpoint' } else { 'capture-endpoint' }
        foreach ($endpoint in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $propertiesPath = Join-Path $endpoint.PSPath 'Properties'
            if (-not (Test-Path -LiteralPath $propertiesPath)) {
                continue
            }

            $properties = Get-ItemProperty -LiteralPath $propertiesPath -ErrorAction SilentlyContinue
            if ($null -eq $properties) {
                continue
            }

            $labels = @(
                $properties.PSObject.Properties |
                    Where-Object { $_.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($_.Value) } |
                    ForEach-Object { [string] $_.Value }
            )
            if ($labels.Count -eq 0) {
                continue
            }

            $name = ($labels | Where-Object { Test-KnownVirtualMicLabel $_ } | Select-Object -First 1)
            if (-not $name) {
                $name = ($labels | Select-Object -First 1)
            }

            $devices += New-DetectedDevice `
                -Kind $kind `
                -Name $name `
                -Id $endpoint.PSChildName `
                -Status 'registered'
        }
    }

    return $devices
}

function Find-VirtualMicDevices {
    $devices = @()
    $devices += Get-PnpMediaDevices
    $devices += Get-RegistryAudioEndpoints

    $matches = @()
    $seen = @{}
    foreach ($device in $devices) {
        $searchText = "$($device.name) $($device.id)"
        if (-not (Test-KnownVirtualMicLabel $searchText)) {
            continue
        }

        $key = "$($device.kind)|$($device.name)|$($device.id)"
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $matches += $device
    }

    return $matches
}

$devices = if (Test-Windows) { Find-VirtualMicDevices } else { @() }
$result = [ordered]@{
    virtualMicReady = ($devices.Count -gt 0)
    devices = $devices
    downloadUrl = $downloadUrl
    nextSteps = @(
        'Install VB-CABLE from the official VB-Audio page.',
        'Run the vendor setup program as Administrator.',
        'Reboot Windows after the driver install.',
        'Select CABLE Input in AudioBridge and CABLE Output in the call app.'
    )
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 4
    exit 0
}

"AudioBridge virtual microphone setup"
""

if (-not (Test-Windows)) {
    "Virtual microphone setup is only needed on Windows."
    exit 0
}

if ($result.virtualMicReady) {
    "Detected a supported virtual microphone/cable driver:"
    foreach ($device in $devices) {
        "  - $($device.name) [$($device.kind), $($device.status)]"
    }
    ""
    "In AudioBridge, select the cable playback endpoint as the Soundboard virtual mic route."
    "In Discord, Zoom, or the game voice chat, select the matching cable recording endpoint as the microphone."
    exit 0
}

"No supported virtual microphone cable was detected."
""
"AudioBridge supports VB-CABLE or Voicemeeter-style virtual cable drivers."
"Install VB-CABLE from the official VB-Audio page, run the vendor setup program as Administrator, then reboot."
"After reboot:"
"  1. Select CABLE Input in AudioBridge as the Soundboard virtual mic route."
"  2. Select CABLE Output in Discord, Zoom, or the game voice chat."
""
"Official VB-CABLE page: $downloadUrl"

if ($OpenDownloadPage) {
    Start-Process $downloadUrl
}
