param(
    [string] $SourceRoot = '',
    [string] $Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Join-Path $repoRoot 'third_party\windows-driver-samples'
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $git) {
    throw 'git.exe is required to fetch the Microsoft Windows Driver Samples repository.'
}

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    git clone --filter=blob:none --sparse --branch $Branch `
        https://github.com/microsoft/Windows-driver-samples.git `
        $SourceRoot
}

git -C $SourceRoot sparse-checkout set audio/sysvad
git -C $SourceRoot submodule update --init wil

$sysvad = Join-Path $SourceRoot 'audio\sysvad'
if (-not (Test-Path -LiteralPath $sysvad)) {
    throw "SYSVAD was not found after checkout: $sysvad"
}

"SYSVAD source is ready at $sysvad"
"Next: .\scripts\build_virtual_mic_driver.ps1 -SourceRoot `"$SourceRoot`""
