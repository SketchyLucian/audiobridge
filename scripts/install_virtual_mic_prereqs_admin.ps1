Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageId = 'Microsoft.WindowsWDK.10.0.26100'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$logPath = Join-Path $repoRoot 'logs\wdksetup-26100.log'

New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($null -eq $winget) {
    throw 'winget.exe is required to install the Windows Driver Kit from this script.'
}

$arguments = @(
    'install',
    '--id', $packageId,
    '--exact',
    '--accept-package-agreements',
    '--accept-source-agreements'
)

"Installing Windows Driver Kit package $packageId."
"Run this script from an elevated PowerShell session. The WDK installer may still prompt for elevation."
& $winget.Source @arguments

if ($LASTEXITCODE -ne 0) {
    throw "WDK install failed with exit code $LASTEXITCODE. If the code is 0x80070642, Windows cancelled elevation or the installer UI was closed."
}

& (Join-Path $PSScriptRoot 'check_virtual_mic_prereqs.ps1')
