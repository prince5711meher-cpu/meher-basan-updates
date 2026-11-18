param(
    [Parameter(Mandatory=$true)]
    [string]$ApkPath,

    [Parameter(Mandatory=$true)]
    [string]$VersionName,

    [Parameter(Mandatory=$true)]
    [int]$VersionCode,

    [string]$ReleaseNotes = "App improvements and bug fixes."
)

$ErrorActionPreference = "Stop"

$Repo = "prince5711meher-cpu/meher-basan-updates"
$ExpectedPackage = "com.aistudio.meherbasan.xqzlk"
$ExpectedCert = "3E074CDADD ECDA29AB88FF004263AE6500DCFCD0530CA71D3D238E9AB4A39DF3"
$ExpectedCert = $ExpectedCert -replace '\s', ''

# Always work from this script's repository
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

Write-Host "`nChecking repository..."

$GitStatus = git status --porcelain
if ($LASTEXITCODE -ne 0) { throw "Cannot check Git status." }
if ($GitStatus) {
    throw "Git working tree is not clean. Commit or resolve changes first."
}

if (!(Test-Path ".\docs\update.json")) {
    throw "Existing update manifest not found."
}

$Current = Get-Content ".\docs\update.json" -Raw | ConvertFrom-Json

if ($VersionCode -le [int]$Current.versionCode) {
    throw "New versionCode must be greater than $($Current.versionCode)."
}

if (!(Test-Path $ApkPath)) {
    throw "APK not found: $ApkPath"
}

$ApkPath = (Resolve-Path $ApkPath).Path

# Locate Android SDK build tools
$Sdk = $env:ANDROID_SDK_ROOT
if (!$Sdk) { $Sdk = $env:ANDROID_HOME }
if (!$Sdk) { $Sdk = Join-Path $env:LOCALAPPDATA "Android\Sdk" }

$BuildTools = Join-Path $Sdk "build-tools"
$Aapt = Get-ChildItem $BuildTools -Filter aapt.exe -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (!$Aapt) {
    throw "aapt.exe not found in Android SDK build-tools."
}

$AaptPath = $Aapt.FullName
$ApkSignerPath = Join-Path (Split-Path $AaptPath -Parent) "apksigner.bat"

if (!(Test-Path $ApkSignerPath)) {
    throw "apksigner.bat not found beside aapt.exe."
}

# Validate package and version
Write-Host "Checking APK package and version..."

$Badging = (& $AaptPath dump badging $ApkPath 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect APK metadata." }

$Match = [regex]::Match(
    $Badging,
    "package:\s+name='([^']+)'\s+versionCode='([^']+)'\s+versionName='([^']*)'"
)

if (!$Match.Success) { throw "Could not read APK package metadata." }

if ($Match.Groups[1].Value -ne $ExpectedPackage) {
    throw "Wrong application ID: $($Match.Groups[1].Value)"
}

if ([int]$Match.Groups[2].Value -ne $VersionCode) {
    throw "APK versionCode does not match the supplied versionCode."
}

if ($Match.Groups[3].Value -ne $VersionName) {
    throw "APK versionName does not match the supplied versionName."
}

# Verify signing certificate
Write-Host "Checking APK signing certificate..."

$SignerOutput = (& $ApkSignerPath verify --print-certs $ApkPath 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed." }

$CertMatch = [regex]::Match(
    $SignerOutput,
    "certificate SHA-256 digest:\s*([A-Fa-f0-9:]+)"
)

if (!$CertMatch.Success) { throw "Could not read signing certificate fingerprint." }

$ActualCert = $CertMatch.Groups[1].Value -replace ':', ''
if ($ActualCert.ToUpper() -ne $ExpectedCert) {
    throw "Signing certificate mismatch. APK will not be published."
}

# Calculate APK checksum
$Hash = (Get-FileHash $ApkPath -Algorithm SHA256).Hash
Write-Host "SHA-256: $Hash"

$Tag = "v$VersionName.$VersionCode"
$AssetName = "meher-basan-v$VersionCode.apk"

# Make sure the release tag does not already exist
$RemoteTag = git ls-remote --tags origin "refs/tags/$Tag" 2>&1
if ($LASTEXITCODE -ne 0) { throw "Could not check remote Git tags." }
if ($RemoteTag) { throw "Tag $Tag already exists. Choose another version." }

# Confirm GitHub authentication
gh auth status
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI authentication failed." }

# Create release and upload APK once, using the desired asset name
Write-Host "`nCreating GitHub Release $Tag..."

$UploadSpec = "$ApkPath#$AssetName"

gh release create $Tag $UploadSpec `
    --repo $Repo `
    --title "Meher Basan Bhandar $VersionName" `
    --notes $ReleaseNotes

if ($LASTEXITCODE -ne 0) {
    throw "GitHub Release creation failed. Existing manifest was not changed."
}

# Create the new manifest only after successful APK upload
$ApkUrl = "https://github.com/$Repo/releases/download/$Tag/$AssetName"

$Manifest = [ordered]@{
    versionCode = $VersionCode
    versionName = $VersionName
    minSupportedVersionCode = [int]$Current.minSupportedVersionCode
    releaseNotes = $ReleaseNotes
    apkUrl = $ApkUrl
    sha256 = $Hash
    mandatory = $false
}

$Json = $Manifest | ConvertTo-Json -Depth 5
$Encoding = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    (Join-Path $RepoRoot "docs\update.json"),
    $Json,
    $Encoding
)

git add docs/update.json
git commit -m "Publish app update $VersionName build $VersionCode"

if ($LASTEXITCODE -ne 0) {
    throw "Manifest commit failed. Release exists; inspect Git status."
}

git push origin main

if ($LASTEXITCODE -ne 0) {
    throw "Manifest push failed. Release exists; retry pushing after checking Git status."
}

Write-Host "`nSUCCESS: Release published."
Write-Host "Tag: $Tag"
Write-Host "Manifest: https://prince5711meher-cpu.github.io/meher-basan-updates/update.json"
Write-Host "APK: $ApkUrl"
