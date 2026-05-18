param(
    [string] $SourceRoot = '',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',
    [ValidateSet('x64', 'Win32', 'ARM64')]
    [string] $Platform = 'x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Join-Path $repoRoot 'third_party\windows-driver-samples'
}

$prereqJson = & (Join-Path $PSScriptRoot 'check_virtual_mic_prereqs.ps1') -AsJson | ConvertFrom-Json
if (-not $prereqJson.readyToBuildDriver) {
    $missing = $prereqJson.missingRequired -join ', '
    throw "Virtual microphone driver prerequisites are missing: $missing"
}

$sysvadRoot = Join-Path $SourceRoot 'audio\sysvad'
$solution = Join-Path $sysvadRoot 'sysvad.sln'
if (-not (Test-Path -LiteralPath $solution)) {
    throw "SYSVAD solution not found at $solution. Run .\scripts\setup_virtual_mic_driver.ps1 first."
}

$msbuild = $prereqJson.checks.msbuild
& $msbuild $solution `
    /m `
    /p:Configuration=$Configuration `
    /p:Platform=$Platform `
    /p:SignMode=TestSign

if ($LASTEXITCODE -ne 0) {
    throw "MSBuild failed with exit code $LASTEXITCODE."
}

$package = Get-ChildItem -LiteralPath $sysvadRoot -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'TabletAudioSample.sys') -PathType Leaf
    } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

if ($null -eq $package) {
    throw 'Build completed, but no SYSVAD driver package folder was found.'
}

"Driver package: $($package.FullName)"
"Install/test requires an elevated shell, test signing, and a reboot before install."
"See windows\virtual_mic\README.md for the manual install commands."
