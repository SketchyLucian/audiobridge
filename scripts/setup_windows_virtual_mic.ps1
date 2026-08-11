[CmdletBinding()]
param(
    [switch] $OpenDownloadPage,
    [switch] $PromptInstallDriver,
    [switch] $InstallDriver,
    [switch] $ValidateBundledDriver,
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$downloadUrl = 'https://vb-audio.com/Cable/'
$licensingUrl = 'https://vb-audio.com/Services/licensing.htm'
$vbCablePackageName = 'VBCABLE_Driver_Pack45.zip'
$vbCablePackagePath = Join-Path $PSScriptRoot $vbCablePackageName
$vbCablePackageSha256 = 'B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB'
$vbCableSetupSignerThumbprint = 'A77952D93229D0EC36E2543081EEA7D125732B9C'
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

function Show-SetupMessage {
    param(
        [string] $Message,
        [string] $Title = 'AudioBridge call microphone setup',
        [ValidateSet('Information', 'Error')]
        [string] $Icon = 'Information'
    )

    Add-Type -AssemblyName System.Windows.Forms
    $messageIcon = if ($Icon -eq 'Error') {
        [System.Windows.Forms.MessageBoxIcon]::Error
    } else {
        [System.Windows.Forms.MessageBoxIcon]::Information
    }
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $messageIcon
    ) | Out-Null
}

function Confirm-VbCableInstall {
    Add-Type -AssemblyName System.Windows.Forms
    $message = @"
AudioBridge needs a virtual audio cable to send soundboard audio to call apps.

Install VB-CABLE now?

VB-CABLE is third-party donationware by VB-Audio Software. The unchanged vendor package is included with AudioBridge under VB-Audio's distribution terms.

Origin: https://vb-cable.com
Licensing and donations: $licensingUrl

Windows will request administrator approval and may show a driver confirmation. You must restart Windows after installation. Windows might also change your default audio device.
"@
    $choice = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Install VB-CABLE for AudioBridge?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return $choice -eq [System.Windows.Forms.DialogResult]::Yes
}

function Remove-ValidatedTemporaryDirectory {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $expectedPrefix = $temporaryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $leafName = Split-Path -Leaf $resolvedPath
    if (-not $resolvedPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leafName.StartsWith('AudioBridge-VBCABLE-', [StringComparison]::Ordinal)) {
        throw "Refusing to remove unexpected temporary directory: $resolvedPath"
    }

    if (Test-Path -LiteralPath $resolvedPath) {
        Remove-Item -LiteralPath $resolvedPath -Recurse -Force
    }
}

function Expand-ValidatedVbCablePackage {
    if (-not (Test-Path -LiteralPath $vbCablePackagePath -PathType Leaf)) {
        throw 'The bundled VB-CABLE package is missing. Repair or reinstall AudioBridge.'
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $vbCablePackagePath).Hash
    if ($actualHash -ne $vbCablePackageSha256) {
        throw 'The bundled VB-CABLE package failed its integrity check.'
    }

    $extractDirectory = Join-Path (
        [IO.Path]::GetTempPath()
    ) ("AudioBridge-VBCABLE-$([Guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $extractDirectory | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($vbCablePackagePath)
        try {
            $extractPrefix = [IO.Path]::GetFullPath($extractDirectory).TrimEnd('\', '/') +
                [IO.Path]::DirectorySeparatorChar
            foreach ($entry in $archive.Entries) {
                $entryPath = [IO.Path]::GetFullPath((Join-Path $extractDirectory $entry.FullName))
                if (-not $entryPath.StartsWith($extractPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'The bundled VB-CABLE package contains an unsafe path.'
                }
            }
        } finally {
            $archive.Dispose()
        }

        Expand-Archive -LiteralPath $vbCablePackagePath -DestinationPath $extractDirectory
        $setupName = if ([Environment]::Is64BitOperatingSystem) {
            'VBCABLE_Setup_x64.exe'
        } else {
            'VBCABLE_Setup.exe'
        }
        $setupPath = Join-Path $extractDirectory $setupName
        $catalogPath = Join-Path $extractDirectory 'vbaudio_cable64_win10.cat'
        if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
            throw 'The bundled VB-CABLE package is incomplete.'
        }

        $setupSignature = Get-AuthenticodeSignature -LiteralPath $setupPath
        if ($setupSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $null -eq $setupSignature.SignerCertificate -or
            $setupSignature.SignerCertificate.Thumbprint -ne $vbCableSetupSignerThumbprint) {
            throw 'The VB-CABLE setup signature could not be verified.'
        }

        $catalogSignature = Get-AuthenticodeSignature -LiteralPath $catalogPath
        if ($catalogSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $null -eq $catalogSignature.SignerCertificate -or
            -not $catalogSignature.SignerCertificate.Subject.Contains(
                'Microsoft Windows Hardware Compatibility Publisher'
            )) {
            throw 'The VB-CABLE driver signature could not be verified.'
        }

        return [pscustomobject]@{
            directory = $extractDirectory
            setupPath = $setupPath
        }
    } catch {
        Remove-ValidatedTemporaryDirectory -Path $extractDirectory
        throw
    }
}

function Install-BundledVbCable {
    $expandedPackage = $null
    try {
        $expandedPackage = Expand-ValidatedVbCablePackage
        $process = Start-Process `
            -FilePath $expandedPackage.setupPath `
            -ArgumentList @('-i', '-h') `
            -Verb RunAs `
            -Wait `
            -PassThru
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "VB-CABLE setup exited with code $($process.ExitCode)."
        }
    } finally {
        if ($null -ne $expandedPackage) {
            Remove-ValidatedTemporaryDirectory -Path $expandedPackage.directory
        }
    }
}

if ($ValidateBundledDriver) {
    $expandedPackage = $null
    try {
        $expandedPackage = Expand-ValidatedVbCablePackage
        "Verified bundled VB-CABLE package: $vbCablePackageSha256"
    } finally {
        if ($null -ne $expandedPackage) {
            Remove-ValidatedTemporaryDirectory -Path $expandedPackage.directory
        }
    }
    exit 0
}

$devices = @(
    if (Test-Windows) {
        Find-VirtualMicDevices
    }
)
$bundledInstallerAvailable = Test-Path -LiteralPath $vbCablePackagePath -PathType Leaf
$nextSteps = if ($bundledInstallerAvailable) {
    @(
        'Accept the optional VB-CABLE installation prompt.',
        'Approve the Windows administrator and driver confirmation prompts.',
        'Reboot Windows after the driver install.',
        'Select CABLE Input in AudioBridge and CABLE Output in the call app.'
    )
} else {
    @(
        'Install VB-CABLE from the official VB-Audio page.',
        'Run the vendor setup program as Administrator.',
        'Reboot Windows after the driver install.',
        'Select CABLE Input in AudioBridge and CABLE Output in the call app.'
    )
}
$result = [ordered]@{
    virtualMicReady = ($devices.Count -gt 0)
    devices = $devices
    downloadUrl = $downloadUrl
    licensingUrl = $licensingUrl
    bundledInstallerAvailable = $bundledInstallerAvailable
    nextSteps = $nextSteps
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

$installApproved = $InstallDriver
if ($PromptInstallDriver) {
    $installApproved = Confirm-VbCableInstall
}

if ($installApproved) {
    try {
        Install-BundledVbCable
        if ($PromptInstallDriver) {
            Show-SetupMessage -Message @"
VB-CABLE setup finished.

Restart Windows before using the Soundboard. After restarting, select CABLE Input in AudioBridge and CABLE Output as the microphone in your call app.
"@
        } else {
            'VB-CABLE setup finished. Restart Windows before using the Soundboard.'
        }
        exit 0
    } catch {
        if ($PromptInstallDriver) {
            Show-SetupMessage `
                -Icon Error `
                -Message "VB-CABLE could not be installed.`n`n$($_.Exception.Message)"
        }
        throw
    }
}

"No supported virtual microphone cable was detected."
""
"AudioBridge supports VB-CABLE or Voicemeeter-style virtual cable drivers."
"VB-CABLE is third-party donationware from VB-Audio Software: $licensingUrl"
"Install VB-CABLE from the official VB-Audio page, run the vendor setup program as Administrator, then reboot."
"After reboot:"
"  1. Select CABLE Input in AudioBridge as the Soundboard virtual mic route."
"  2. Select CABLE Output in Discord, Zoom, or the game voice chat."
""
"Official VB-CABLE page: $downloadUrl"

if ($OpenDownloadPage) {
    Start-Process $downloadUrl
}
