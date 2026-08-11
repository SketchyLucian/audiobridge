[CmdletBinding()]
param(
    [ValidateSet('Release')]
    [string] $Configuration = 'Release',

    [switch] $SkipFlutterBuild,

    [string] $ProductVersion,

    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$wixProjectPath = Join-Path $repoRoot 'installer\windows\AudioBridge.Installer.wixproj'
$bundleDir = Join-Path $repoRoot "build\windows\x64\runner\$Configuration"
$executablePath = Join-Path $bundleDir 'AudioBridge.exe'
$vbCableSourcePath = Join-Path $repoRoot 'third_party\vb-cable\VBCABLE_Driver_Pack45.zip'
$vbCableBundlePath = Join-Path $bundleDir 'VirtualMic\VBCABLE_Driver_Pack45.zip'
$vbCableExpectedSha256 = 'B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB'

function Assert-VbCablePackage {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Bundled VB-CABLE package not found at $Path."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($actualHash -ne $vbCableExpectedSha256) {
        throw "Bundled VB-CABLE package failed its integrity check at $Path."
    }
}

Assert-VbCablePackage -Path $vbCableSourcePath

if (-not $ProductVersion) {
    $versionLine = Get-Content $pubspecPath | Where-Object { $_ -match '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$' } | Select-Object -First 1
    if (-not $versionLine) {
        throw "Unable to find a three-part version in $pubspecPath."
    }

    $ProductVersion = [regex]::Match($versionLine, '([0-9]+\.[0-9]+\.[0-9]+)').Value
}

if ($ProductVersion -notmatch '^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$') {
    throw "MSI ProductVersion must be three numeric parts, for example 1.0.0. Got '$ProductVersion'."
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot 'build\installer'
}

$OutputDirectory = (New-Item -ItemType Directory -Force -Path $OutputDirectory).FullName
$intermediateDirectory = (New-Item -ItemType Directory -Force -Path (Join-Path $OutputDirectory 'obj')).FullName

if (-not $SkipFlutterBuild) {
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows --release failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path $executablePath)) {
    throw "Windows release bundle not found at $bundleDir. Run flutter build windows --release first, or omit -SkipFlutterBuild."
}

Assert-VbCablePackage -Path $vbCableBundlePath

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnetCommand) {
    throw "MSI packaging requires the .NET SDK because the installer uses WiX Toolset. Install .NET SDK 6 or newer, then rerun this script."
}

$sdks = & $dotnetCommand.Source --list-sdks
if (-not $sdks) {
    throw "The dotnet command is present, but no .NET SDK is installed. Install .NET SDK 6 or newer, then rerun this script."
}

$outputPathProperty = $OutputDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$intermediatePathProperty = $intermediateDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$outputName = "AudioBridge-$ProductVersion-x64"

$buildArgs = @(
    'build',
    $wixProjectPath,
    '-c',
    $Configuration,
    "-p:BundleDir=$bundleDir",
    "-p:RepoRoot=$repoRoot",
    "-p:ProductVersion=$ProductVersion",
    "-p:OutputPath=$outputPathProperty",
    "-p:IntermediateOutputPath=$intermediatePathProperty",
    "-p:OutputName=$outputName"
)

& $dotnetCommand.Source @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "WiX MSI build failed with exit code $LASTEXITCODE."
}

$msiPath = Join-Path $OutputDirectory "$outputName.msi"
if (-not (Test-Path $msiPath)) {
    throw "WiX build completed, but expected MSI was not found at $msiPath."
}

Write-Host "MSI created: $msiPath"
