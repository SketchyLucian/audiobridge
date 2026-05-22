[CmdletBinding()]
param(
    [switch] $SkipWindowsBuild,

    [switch] $SkipAndroidBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot

function Invoke-DevStep {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [scriptblock] $Command
    )

    Write-Host ''
    Write-Host "==> $Name"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

Invoke-DevStep 'Install dependencies' { flutter pub get }
Invoke-DevStep 'Analyze' { flutter analyze }
Invoke-DevStep 'Test' { flutter test }
Invoke-DevStep 'Android native unit tests' {
    Push-Location (Join-Path $repoRoot 'android')
    try {
        .\gradlew.bat :app:testDebugUnitTest
    } finally {
        Pop-Location
    }
}

if ($SkipWindowsBuild) {
    Write-Host ''
    Write-Host '==> Skipping Windows debug build'
} else {
    Invoke-DevStep 'Build Windows debug app' { flutter build windows --debug }
}

if ($SkipAndroidBuild) {
    Write-Host ''
    Write-Host '==> Skipping Android debug APK build'
} else {
    Invoke-DevStep 'Build Android debug APK' { flutter build apk --debug }
}
