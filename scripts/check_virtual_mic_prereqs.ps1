param(
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-FirstExisting {
    param([string[]] $Paths)

    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Find-FirstByPattern {
    param(
        [string] $Root,
        [string] $Filter
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $match = Get-ChildItem -LiteralPath $Root -Recurse -Filter $Filter -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.FullName
}

function Find-MsBuild {
    $pathMatch = (Get-Command msbuild.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($null -ne $pathMatch) {
        return $pathMatch.Source
    }

    $roots = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
        "$env:ProgramFiles\Microsoft Visual Studio"
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $root -Recurse -Filter MSBuild.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\MSBuild\\(Current|[0-9.]+)\\Bin\\MSBuild\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($null -ne $match) {
            return $match.FullName
        }
    }

    return $null
}

function Find-WindowsKitVersion {
    $includeRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\Include"
    if (-not (Test-Path -LiteralPath $includeRoot)) {
        return $null
    }

    $version = Get-ChildItem -LiteralPath $includeRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($null -eq $version) {
        return $null
    }

    return $version.Name
}

function Find-DriverToolset {
    param(
        [string] $Name,
        [string] $KitName
    )

    $roots = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
        "${env:ProgramFiles(x86)}\Windows Kits\10",
        "$env:ProgramFiles\Microsoft Visual Studio"
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer -and $_.Name -eq $Name } |
            Select-Object -First 1
        if ($null -ne $match) {
            return $match.FullName
        }
    }

    $kitBuildRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\build"
    if (Test-Path -LiteralPath $kitBuildRoot) {
        $match = Get-ChildItem -LiteralPath $kitBuildRoot -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer -and $_.Name -eq $KitName } |
            Select-Object -First 1
        if ($null -ne $match) {
            return $match.FullName
        }
    }

    return $null
}

$kitRoot = "${env:ProgramFiles(x86)}\Windows Kits\10"
$kitVersion = Find-WindowsKitVersion
$kitBin = if ($kitVersion) { Join-Path $kitRoot "bin\$kitVersion\x64" } else { $null }
$kitTools = Join-Path $kitRoot 'Tools\x64'

$checks = [ordered]@{
    msbuild = Find-MsBuild
    windowsKitRoot = if (Test-Path -LiteralPath $kitRoot) { $kitRoot } else { $null }
    windowsKitVersion = $kitVersion
    signtool = Find-FirstExisting @(
        $(if ($kitBin) { Join-Path $kitBin 'signtool.exe' } else { $null }),
        (Find-FirstByPattern -Root $kitRoot -Filter signtool.exe)
    )
    inf2cat = Find-FirstExisting @(
        $(if ($kitBin) { Join-Path $kitBin 'inf2cat.exe' } else { $null }),
        (Find-FirstByPattern -Root $kitRoot -Filter inf2cat.exe)
    )
    driverToolsetKernel = Find-DriverToolset `
        -Name 'WindowsKernelModeDriver10.0' `
        -KitName 'WindowsKernelModeDriver'
    driverToolsetApp = Find-DriverToolset `
        -Name 'WindowsApplicationForDrivers10.0' `
        -KitName 'WindowsApplicationForDrivers'
    devcon = Find-FirstExisting @(
        (Join-Path $kitTools 'devcon.exe'),
        (Find-FirstByPattern -Root $kitRoot -Filter devcon.exe)
    )
    git = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
}

$required = @(
    'msbuild',
    'windowsKitRoot',
    'windowsKitVersion',
    'signtool',
    'inf2cat',
    'driverToolsetKernel',
    'driverToolsetApp',
    'git'
)
$missingRequired = @(
    foreach ($name in $required) {
        if (-not $checks[$name]) {
            $name
        }
    }
)

$result = [ordered]@{
    readyToBuildDriver = ($missingRequired.Count -eq 0)
    missingRequired = $missingRequired
    checks = $checks
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 4
    exit 0
}

"AudioBridge virtual microphone driver prerequisites"
"Ready to build driver: $($result.readyToBuildDriver)"
if ($missingRequired.Count -gt 0) {
    "Missing required: $($missingRequired -join ', ')"
}
""
foreach ($entry in $checks.GetEnumerator()) {
    $value = if ($entry.Value) { $entry.Value } else { '<missing>' }
    "{0,-18} {1}" -f $entry.Key, $value
}

if ($missingRequired.Count -gt 0) {
    ""
    "Install or repair the Windows Driver Kit from an elevated shell, then rerun this check."
    "Expected missing toolsets are installed by the WDK, not by the normal Windows SDK."
    exit 1
}
