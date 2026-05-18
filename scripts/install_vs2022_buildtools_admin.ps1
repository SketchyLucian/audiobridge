Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($null -eq $winget) {
    throw 'winget.exe is required to install Visual Studio Build Tools 2022 from this script.'
}

$override = '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'

"Installing Visual Studio Build Tools 2022 C++ workload."
"Run this script from an elevated PowerShell session. The installer may still prompt for elevation."
& $winget.Source install `
    --id Microsoft.VisualStudio.2022.BuildTools `
    --exact `
    --accept-package-agreements `
    --accept-source-agreements `
    --override $override

if ($LASTEXITCODE -ne 0) {
    throw "Visual Studio Build Tools 2022 install failed with exit code $LASTEXITCODE."
}

"Visual Studio Build Tools 2022 install completed."
