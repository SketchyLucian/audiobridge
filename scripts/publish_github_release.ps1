[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $Tag,

    [Parameter(Mandatory)]
    [string] $WindowsMsi,

    [Parameter(Mandatory)]
    [string] $AndroidApk,

    [string] $Owner = 'SketchyLucian',

    [string] $Repository = 'audiobridge-releases',

    [string] $Token = $env:GH_RELEASE_TOKEN,

    [string] $ReleaseNotes,

    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ReleaseArtifact {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $ExpectedName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required release artifact was not found: $Path"
    }

    $artifact = Get-Item -LiteralPath $Path
    if ($artifact.Name -cne $ExpectedName) {
        throw "Expected release artifact '$ExpectedName', got '$($artifact.Name)'."
    }
    if ($artifact.Length -le 0) {
        throw "Release artifact is empty: $Path"
    }
    return $artifact
}

function Get-GitHubCredentialHeaders {
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'GH_RELEASE_TOKEN is required to publish a release.'
    }
    return @{
        Authorization = "Bearer $Token"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'AudioBridge-release-publisher'
    }
}

function Get-GitHubResourceOrNull {
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [hashtable] $Headers
    )

    try {
        return Invoke-RestMethod -Uri $Uri -Headers $Headers
    } catch {
        if ([int] $_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Add-ReleaseAsset {
    param(
        [Parameter(Mandatory)]
        [long] $ReleaseId,

        [Parameter(Mandatory)]
        [System.IO.FileInfo] $Artifact,

        [Parameter(Mandatory)]
        [hashtable] $Headers,

        [object[]] $ExistingAssets = @()
    )

    $existing = $ExistingAssets |
        Where-Object { $_.name -ceq $Artifact.Name } |
        Select-Object -First 1
    if ($null -ne $existing) {
        if ([long] $existing.size -eq $Artifact.Length) {
            return $existing
        }
        Invoke-RestMethod `
            -Method Delete `
            -Uri "https://api.github.com/repos/$Owner/$Repository/releases/assets/$($existing.id)" `
            -Headers $Headers | Out-Null
    }

    $encodedName = [Uri]::EscapeDataString($Artifact.Name)
    return Invoke-RestMethod `
        -Method Post `
        -Uri "https://uploads.github.com/repos/$Owner/$Repository/releases/$ReleaseId/assets?name=$encodedName" `
        -Headers $Headers `
        -ContentType 'application/octet-stream' `
        -InFile $Artifact.FullName
}

$version = $Tag.Substring(1)
$expectedMsiName = "AudioBridge-$version-x64.msi"
$expectedApkName = "AudioBridge-$version-android.apk"
$msi = Resolve-ReleaseArtifact -Path $WindowsMsi -ExpectedName $expectedMsiName
$apk = Resolve-ReleaseArtifact -Path $AndroidApk -ExpectedName $expectedApkName

Write-Host "Validated Windows release artifact: $($msi.FullName)"
Write-Host "Validated Android release artifact: $($apk.FullName)"
if ($ValidateOnly) {
    Write-Host "Release contract satisfied for $Tag."
    return
}

$headers = Get-GitHubCredentialHeaders
$repoApi = "https://api.github.com/repos/$Owner/$Repository"
$repo = Invoke-RestMethod -Uri $repoApi -Headers $headers
if ($repo.private -or $repo.visibility -ne 'public') {
    throw "$Owner/$Repository must be public before publishing releases."
}
if (-not $repo.has_downloads) {
    throw "Releases are disabled for $Owner/$Repository."
}

$release = Get-GitHubResourceOrNull `
    -Uri "$repoApi/releases/tags/$Tag" `
    -Headers $headers
if ($null -ne $release -and -not $release.draft) {
    throw "$Tag is already published. Refusing to replace a public release."
}

if ($null -eq $release) {
    $createPayload = @{
        tag_name = $Tag
        target_commitish = $repo.default_branch
        name = "AudioBridge $version"
        body = 'Release artifacts are being verified.'
        draft = $true
        prerelease = $false
    } | ConvertTo-Json
    $release = Invoke-RestMethod `
        -Method Post `
        -Uri "$repoApi/releases" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $createPayload
}

$existingAssets = @($release.assets)
$uploadedMsi = Add-ReleaseAsset `
    -ReleaseId $release.id `
    -Artifact $msi `
    -Headers $headers `
    -ExistingAssets $existingAssets
$uploadedApk = Add-ReleaseAsset `
    -ReleaseId $release.id `
    -Artifact $apk `
    -Headers $headers `
    -ExistingAssets $existingAssets

$release = Invoke-RestMethod -Uri "$repoApi/releases/$($release.id)" -Headers $headers
$requiredAssets = @(
    @{ Name = $expectedMsiName; Size = $msi.Length },
    @{ Name = $expectedApkName; Size = $apk.Length }
)
foreach ($required in $requiredAssets) {
    $matches = @($release.assets | Where-Object {
        $_.name -ceq $required.Name -and [long] $_.size -eq $required.Size
    })
    if ($matches.Count -ne 1) {
        throw "Draft release does not contain exactly one valid '$($required.Name)' asset."
    }
}

$msiSha = (Get-FileHash -LiteralPath $msi.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$apkSha = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($ReleaseNotes)) {
    $ReleaseNotes = @(
        '## Downloads',
        '',
        "- Windows: $expectedMsiName",
        "- Android: $expectedApkName",
        '',
        '## SHA-256',
        '',
        "- ${expectedMsiName}: $msiSha",
        "- ${expectedApkName}: $apkSha"
    ) -join "`n"
}

$publishPayload = @{
    tag_name = $Tag
    name = "AudioBridge $version"
    body = $ReleaseNotes
    draft = $false
    prerelease = $false
    make_latest = 'true'
} | ConvertTo-Json
$published = Invoke-RestMethod `
    -Method Patch `
    -Uri "$repoApi/releases/$($release.id)" `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body $publishPayload

Write-Host "Published complete release: $($published.html_url)"
Write-Host "Windows asset: $($uploadedMsi.browser_download_url)"
Write-Host "Android asset: $($uploadedApk.browser_download_url)"
