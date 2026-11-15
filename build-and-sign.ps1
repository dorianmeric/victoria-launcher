#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the release APK and signs it with the APK Signature Scheme v2, v3 and v4.

.DESCRIPTION
    Runs the Gradle release build, aligns the result, signs it with apksigner using the v2,
    v3 and v4 schemes — and verifies that all three are there and that no v1 (JAR) or v3.1
    signature is. The signed APK and the v4 signature file it needs are left in dist/
    (gitignored) under a versioned name, along with the package id and app label it was built
    with.

    Signing details come from keystore.properties in the repository root (gitignored, like
    the keystore it names). On a fresh clone there is no keystore yet, so create both with:

        keytool -genkeypair -v -keystore release.keystore -alias victoria `
                -keyalg RSA -keysize 4096 -validity 10000 -storetype JKS `
                -storepass <password> -keypass <password> `
                -dname "CN=Victoria Launcher (local), OU=Local, O=Local, L=Local, ST=Local, C=US"

        @"
        storeFile=release.keystore
        storePassword=<password>
        keyAlias=victoria
        keyPassword=<password>
        "@ | Set-Content keystore.properties

    Keep those two files together: the same key is what lets a later build install over an
    earlier one without uninstalling first. Losing it means uninstalling to update.

.PARAMETER SdkDir
    Android SDK root. Defaults to ANDROID_HOME, then ANDROID_SDK_ROOT, then sdk.dir from
    local.properties, then the usual install locations.

.PARAMETER BuildToolsVersion
    Version under <SdkDir>/build-tools to sign with. Defaults to the highest one installed.

.PARAMETER KeystoreProperties
    The signing config to read. Defaults to keystore.properties in the repository root.

.PARAMETER OutputDirectory
    Where the signed APK is written. Defaults to dist/.

.PARAMETER Variant
    Build variant to assemble. Defaults to release.

.PARAMETER SkipBuild
    Re-sign whatever the last build already produced, without running Gradle.

.EXAMPLE
    ./build-and-sign.ps1

.EXAMPLE
    ./build-and-sign.ps1 -SdkDir 'C:\P\Android-CLI' -OutputDirectory 'C:\apks'
#>
[CmdletBinding()]
param(
    [string]$SdkDir,
    [string]$BuildToolsVersion,
    [string]$KeystoreProperties = (Join-Path $PSScriptRoot 'keystore.properties'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$Variant = 'release',
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$isWindowsHost = $env:OS -eq 'Windows_NT'

function Read-Properties([string]$Path) {
    $properties = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed.StartsWith('!')) { continue }
        $equals = $trimmed.IndexOf('=')
        if ($equals -lt 1) { continue }
        $properties[$trimmed.Substring(0, $equals).Trim()] = $trimmed.Substring($equals + 1).Trim()
    }
    $properties
}

function Resolve-SdkDir {
    $candidates = @()
    if ($SdkDir) { $candidates += $SdkDir }
    if ($env:ANDROID_HOME) { $candidates += $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT) { $candidates += $env:ANDROID_SDK_ROOT }
    $localProperties = Join-Path $repoRoot 'local.properties'
    if (Test-Path -LiteralPath $localProperties) {
        $properties = Read-Properties $localProperties
        if ($properties.ContainsKey('sdk.dir')) {
            # local.properties is a Java properties file: backslashes and colons are escaped.
            $candidates += ($properties['sdk.dir'] -replace '\\\\', '\' -replace '\\:', ':')
        }
    }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
    if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'Android\Sdk') }
    $candidates += '/usr/local/lib/android/sdk'

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ((Test-Path -LiteralPath (Join-Path $candidate 'platforms')) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'build-tools'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Android SDK not found. Pass -SdkDir, set ANDROID_HOME, or put sdk.dir in local.properties."
}

function Resolve-BuildTools([string]$SdkDir, [string]$Wanted) {
    $root = Join-Path $SdkDir 'build-tools'
    $installed = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'lib/apksigner.jar')) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName 'apksigner.bat')) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName 'apksigner'))
        }
    if ($null -eq $installed -or @($installed).Count -eq 0) {
        throw "No build-tools with apksigner found under $root."
    }
    if ($Wanted) {
        $match = $installed | Where-Object { $_.Name -eq $Wanted }
        if (-not $match) { throw "build-tools $Wanted is not installed under $root." }
        return $match.FullName
    }
    # Highest version wins, compared as numbers rather than as strings.
    $installed |
        Sort-Object { [version](($_.Name -split '-')[0]) } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments, [string]$What) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

# --- Signing material ------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $KeystoreProperties)) {
    throw "Missing $KeystoreProperties. See the comment block at the top of this script for how to create it."
}

$signing = Read-Properties $KeystoreProperties
foreach ($required in 'storeFile', 'storePassword', 'keyAlias', 'keyPassword') {
    if (-not $signing.ContainsKey($required) -or -not $signing[$required]) {
        throw "$KeystoreProperties is missing '$required'."
    }
}

$keystorePath = $signing['storeFile']
if (-not [IO.Path]::IsPathRooted($keystorePath)) {
    $keystorePath = Join-Path $repoRoot $keystorePath
}
if (-not (Test-Path -LiteralPath $keystorePath)) {
    throw "Keystore $keystorePath does not exist; storeFile in $KeystoreProperties points at it."
}

# --- Toolchain -------------------------------------------------------------------------

$sdkRoot = Resolve-SdkDir
$buildTools = Resolve-BuildTools $sdkRoot $BuildToolsVersion
$apksigner = if ($isWindowsHost) { Join-Path $buildTools 'apksigner.bat' } else { Join-Path $buildTools 'apksigner' }
$zipalign = if ($isWindowsHost) { Join-Path $buildTools 'zipalign.exe' } else { Join-Path $buildTools 'zipalign' }
$aapt2 = if ($isWindowsHost) { Join-Path $buildTools 'aapt2.exe' } else { Join-Path $buildTools 'aapt2' }

# Gradle picks the SDK up from the environment when there is no local.properties.
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot

Write-Host "SDK:         $sdkRoot"
Write-Host "Build tools: $(Split-Path -Leaf $buildTools)"
Write-Host "Keystore:    $keystorePath"

# --- Build -----------------------------------------------------------------------------

$variantName = $Variant.Substring(0, 1).ToUpperInvariant() + $Variant.Substring(1)
if (-not $SkipBuild) {
    Write-Host ''
    Write-Host "Building :app:assemble$variantName ..."
    $gradlew = if ($isWindowsHost) { Join-Path $repoRoot 'gradlew.bat' } else { Join-Path $repoRoot 'gradlew' }
    Invoke-Native $gradlew @(":app:assemble$variantName", '--console=plain') 'Gradle build'
}

$apkDirectory = Join-Path $repoRoot "app/build/outputs/apk/$Variant"
$builtApk = Get-Item -LiteralPath (Join-Path $apkDirectory "app-$Variant.apk") -ErrorAction SilentlyContinue
if (-not $builtApk) {
    # An unsigned variant build drops its suffix into the same directory.
    $builtApk = Get-ChildItem -LiteralPath $apkDirectory -Filter 'app-*.apk' -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
}
if (-not $builtApk) {
    throw "No APK found in $apkDirectory. Run without -SkipBuild, or build :app:assemble$variantName first."
}
Write-Host "Built:       $($builtApk.FullName)"

# --- Name the output after what was actually built --------------------------------------

$versionName = 'unknown'
if (Test-Path -LiteralPath $aapt2) {
    $badging = & $aapt2 dump badging $builtApk.FullName 2>$null
    # Anchored on the whole line rather than a greedy .* so the last versionName on it —
    # the platform's own, not the app's — cannot win.
    $versionLine = $badging |
        Select-String -Pattern "^package: name='[^']*' versionCode='[^']*' versionName='([^']*)'" |
        Select-Object -First 1
    if ($versionLine -and $versionLine.Matches.Count -gt 0) { $versionName = $versionLine.Matches[0].Groups[1].Value }
}
$outputName = "victoria-launcher-mine-$versionName-signed.apk"

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$finalApk = Join-Path $OutputDirectory $outputName
if (Test-Path -LiteralPath $finalApk) { Remove-Item -LiteralPath $finalApk -Force }

# apksigner writes the v4 signature beside the APK rather than inside it, so the two travel
# and are verified together.
$idsig = "$finalApk.idsig"
if (Test-Path -LiteralPath $idsig) { Remove-Item -LiteralPath $idsig -Force }

$stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) ('victoria-sign-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
$stagedApk = Join-Path $stagingDirectory 'aligned.apk'
$ksPasswordFile = Join-Path $stagingDirectory 'ks-pass.txt'
$keyPasswordFile = Join-Path $stagingDirectory 'key-pass.txt'

try {
    # v2 covers the whole file, so alignment has to be right before it is written. The page
    # size matches what Android 15 expects of the uncompressed libraries in the APK.
    Invoke-Native $zipalign @('-f', '-P', '16', '4', $builtApk.FullName, $stagedApk) 'zipalign'

    # Passwords by file rather than on the command line, so they stay out of the process list.
    [IO.File]::WriteAllText($ksPasswordFile, $signing['storePassword'])
    [IO.File]::WriteAllText($keyPasswordFile, $signing['keyPassword'])

    Write-Host ''
    Write-Host 'Signing with APK Signature Schemes v2, v3 and v4 ...'
    Invoke-Native $apksigner @(
        'sign',
        '--ks', $keystorePath,
        '--ks-key-alias', $signing['keyAlias'],
        '--ks-pass', "file:$ksPasswordFile",
        '--key-pass', "file:$keyPasswordFile",
        # v1 is off because minSdk is 26: the oldest device this installs on reads v2.
        '--v1-signing-enabled', 'false',
        '--v2-signing-enabled', 'true',
        '--v3-signing-enabled', 'true',
        '--v4-signing-enabled', 'true',
        '--out', $finalApk,
        $stagedApk
    ) 'apksigner sign'

    if (-not (Test-Path -LiteralPath $idsig)) {
        throw "apksigner did not write the v4 signature file $idsig."
    }
}
finally {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Verify what was written -----------------------------------------------------------

$verification = (& $apksigner verify --print-certs -v --v4-signature-file $idsig $finalApk 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "The signed APK does not verify:`n$verification"
}
# v4 is only read when its file is handed over, which is why the check above names it; without
# that the APK would look v2/v3 signed and the idsig could be anything.
$schemes = [ordered]@{
    'v1 (JAR signing)'                 = @{ Pattern = 'Verified using v1 scheme \(JAR signing\): true'; Required = $false }
    'v2 (APK Signature Scheme v2)'     = @{ Pattern = 'Verified using v2 scheme \(APK Signature Scheme v2\): true'; Required = $true }
    'v3 (APK Signature Scheme v3)'     = @{ Pattern = 'Verified using v3 scheme \(APK Signature Scheme v3\): true'; Required = $true }
    'v3.1 (APK Signature Scheme v3.1)' = @{ Pattern = 'Verified using v3.1 scheme \(APK Signature Scheme v3.1\): true'; Required = $false }
    'v4 (APK Signature Scheme v4)'     = @{ Pattern = 'Verified using v4 scheme \(APK Signature Scheme v4\): true'; Required = $true }
}
foreach ($scheme in $schemes.GetEnumerator()) {
    $present = $verification -match $scheme.Value.Pattern
    if ($scheme.Value.Required -and -not $present) {
        throw "The APK carries no $($scheme.Key) signature:`n$verification"
    }
    if (-not $scheme.Value.Required -and $present) {
        throw "The APK also carries a $($scheme.Key) signature; this script signs v2, v3 and v4 only:`n$verification"
    }
}
Invoke-Native $zipalign @('-c', '-P', '16', '4', $finalApk) 'zipalign check' | Out-Null

$signer = ($verification | Select-String -Pattern 'Signer #1 certificate SHA-256 digest: (\S+)' | Select-Object -First 1)
$aaptDump = if (Test-Path -LiteralPath $aapt2) { (& $aapt2 dump badging $finalApk 2>$null | Out-String) } else { '' }
$packageName = if ($aaptDump -match "package: name='([^']*)'") { $Matches[1] } else { '(unknown)' }
$appLabel = if ($aaptDump -match "application-label:'([^']*)'") { $Matches[1] } else { '(unknown)' }
$apkHash = (Get-FileHash -LiteralPath $finalApk -Algorithm SHA256).Hash

Write-Host ''
Write-Host "Signed APK:  $finalApk"
Write-Host "V4 idsig:    $idsig"
Write-Host "Package:     $packageName"
Write-Host "Label:       $appLabel"
Write-Host "Version:     $versionName"
Write-Host "SHA-256:     $($apkHash.ToLowerInvariant())"
if ($signer) { Write-Host "Signer:      $($signer.Matches[0].Groups[1].Value)" }
Write-Host 'Signature:   v2, v3 and v4 present (v1 and v3.1 absent)'