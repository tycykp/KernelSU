#!/usr/bin/env pwsh
<#
.SYNOPSIS
Builds the KernelSU Manager APK.

.DESCRIPTION
Locates the JDK and Android SDK, prepares the manager sources (including the
ksud daemon binary when available) and runs the Gradle build. On Windows it
also repairs the broken "cpp/uapi" git symlink automatically and restores it
after the build.

Requirements:
  - JDK 17 or newer (Temurin 21 recommended)
  - Android SDK with platform android-37.0, build-tools 37.0.0 and NDK 29
    (Gradle can auto-install missing packages when SDK licenses are accepted)
  - Network access for Gradle dependency resolution

.PARAMETER Variant
Build variant: Debug (default) or Release.

.PARAMETER SkipClean
Skip the "clean" task and reuse previous build outputs.

.PARAMETER JdkHome
Path to a JDK root containing bin\javac.exe. Auto-detected when omitted.

.PARAMETER SdkHome
Path to an Android SDK root. Auto-detected when omitted.

.PARAMETER BuildKsud
Build the arm64 ksud daemon from this repository with "cargo ndk" and embed it.
The ksud source is identical to original KernelSU at the same commit, so this
preserves the original root behavior.

.PARAMETER UseOfficialKsud
Download the latest official KernelSU release APK and embed its original ksud
binaries (arm64-v8a and x86_64) into the build.

.PARAMETER KsudBinary
Path to a ksud binary (arm64) to embed. Useful when you have a ksud extracted
from an official KernelSU manager APK.

.PARAMETER SkipKsud
Do not embed any ksud daemon. The resulting APK will not be able to grant root.

.PARAMETER Sign
Sign the APK with a custom manager key. The official KernelSU kernel only
accepts managers signed with the official certificate, so a custom manager
also requires rebuilding kernelsu.ko with KSU_EXPECTED_SIZE2/HASH2 (the values
are printed by this script).

.PARAMETER Keystore
Path to the custom keystore used with -Sign. Generated at manager\ksu-custom.jks
when omitted.

.PARAMETER KeystorePassword
Keystore password for -Sign (default: kernelsu).

.PARAMETER KeyAlias
Key alias for -Sign (default: ksu).

.PARAMETER KeyPassword
Key password for -Sign (default: same as -KeystorePassword).

.EXAMPLE
./scripts/build-apk.ps1

.EXAMPLE
./scripts/build-apk.ps1 -Variant Release -BuildKsud
#>
[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Variant = "Debug",
    [switch]$SkipClean,
    [string]$JdkHome = "",
    [string]$SdkHome = "",
    [switch]$BuildKsud,
    [switch]$UseOfficialKsud,
    [string]$KsudBinary = "",
    [switch]$SkipKsud,
    [switch]$Sign,
    [string]$Keystore = "",
    [string]$KeystorePassword = "",
    [string]$KeyAlias = "",
    [string]$KeyPassword = ""
)

$ErrorActionPreference = "Stop"
$script:IsWindows = $env:OS -eq "Windows_NT"
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ManagerDir = Join-Path $script:RepoRoot "manager"
$script:UapiPath = Join-Path $script:ManagerDir "app\src\main\cpp\uapi"
$script:UapiOriginal = $null

function Write-Step([string]$Message) {
    Write-Host "[build] $Message" -ForegroundColor Cyan
}

function Resolve-Jdk {
    if ($JdkHome) {
        if (Test-Path (Join-Path $JdkHome "bin\javac.exe")) { return $JdkHome }
        throw "JdkHome '$JdkHome' does not contain bin\javac.exe"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:JAVA_HOME) { $candidates.Add($env:JAVA_HOME) }
    $javac = Get-Command javac -ErrorAction SilentlyContinue
    if ($javac) { $candidates.Add((Split-Path (Split-Path $javac.Source -Parent) -Parent)) }
    Get-ChildItem (Join-Path $env:USERPROFILE ".jdks") -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $candidates.Add($_.FullName) }
    $candidates.Add("$env:LOCALAPPDATA\Programs\Android Studio\jbr")
    $candidates.Add("C:\Program Files\Android\Android Studio\jbr")

    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate "bin\javac.exe")) { return $candidate }
    }
    throw "JDK 17+ not found. Install Temurin 21 or pass -JdkHome <path>."
}

function Resolve-Sdk {
    if ($SdkHome) {
        if (Test-Path (Join-Path $SdkHome "platforms")) { return $SdkHome }
        throw "SdkHome '$SdkHome' does not look like an Android SDK (no 'platforms' directory)"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ANDROID_HOME) { $candidates.Add($env:ANDROID_HOME) }
    if ($env:ANDROID_SDK_ROOT) { $candidates.Add($env:ANDROID_SDK_ROOT) }
    $localProperties = Join-Path $script:ManagerDir "local.properties"
    if (Test-Path $localProperties) {
        $line = Get-Content $localProperties | Where-Object { $_ -match "^sdk\.dir=" } | Select-Object -First 1
        if ($line) {
            $candidates.Add(($line -replace "^sdk\.dir=", "" -replace '\\:', ':'))
        }
    }
    $candidates.Add("$env:LOCALAPPDATA\Android\Sdk")
    $candidates.Add("$env:USERPROFILE\Android\Sdk")
    $candidates.Add("C:\Android\Sdk")

    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate "platforms")) { return $candidate }
    }
    throw "Android SDK not found. Install it or pass -SdkHome <path>."
}

function Repair-Uapi {
    if (-not $script:IsWindows) { return }
    if (Test-Path $script:UapiPath -PathType Container) { return }
    $item = Get-Item $script:UapiPath -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return }

    # On Windows, git checks the "uapi" symlink out as a plain text file,
    # which breaks the native build. Replace it with a junction temporarily.
    $text = [System.IO.File]::ReadAllText($script:UapiPath)
    if ($text -match "\.\./uapi") {
        $script:UapiOriginal = [System.IO.File]::ReadAllBytes($script:UapiPath)
        [System.IO.File]::Delete($script:UapiPath)
        New-Item -ItemType Junction -Path $script:UapiPath -Target (Join-Path $script:RepoRoot "uapi") | Out-Null
        Write-Step "Repaired broken 'cpp/uapi' git symlink with a junction."
    }
}

function Restore-Uapi {
    if ($null -eq $script:UapiOriginal) { return }
    if (Test-Path $script:UapiPath) {
        cmd /c rmdir "$script:UapiPath" 2>$null
    }
    [System.IO.File]::WriteAllBytes($script:UapiPath, $script:UapiOriginal)
    $script:UapiOriginal = $null
    Write-Step "Restored 'cpp/uapi' symlink file."
}

function Prepare-Ksud {
    if ($SkipKsud) {
        Write-Warning "Skipping ksud embedding (-SkipKsud); the APK will not grant root."
        return
    }

    if ($KsudBinary) {
        if (-not (Test-Path $KsudBinary)) { throw "KsudBinary not found: $KsudBinary" }
        $jniDir = Join-Path $script:ManagerDir "app\src\main\jniLibs\arm64-v8a"
        New-Item -ItemType Directory -Path $jniDir -Force | Out-Null
        Copy-Item -LiteralPath $KsudBinary -Destination (Join-Path $jniDir "libksud.so") -Force
        Write-Step "Embedded ksud from $KsudBinary"
        return
    }

    if ($UseOfficialKsud) {
        Get-OfficialKsud
        return
    }

    if ($BuildKsud) {
        Build-KsudFromSource $sdk
        return
    }

    $ksudCandidates = @(
        (Join-Path $script:RepoRoot "target\aarch64-linux-android\release\ksud"),
        (Join-Path $script:RepoRoot "userspace\ksud\target\aarch64-linux-android\release\ksud")
    )
    foreach ($ksud in $ksudCandidates) {
        if (Test-Path $ksud) {
            $jniDir = Join-Path $script:ManagerDir "app\src\main\jniLibs\arm64-v8a"
            New-Item -ItemType Directory -Path $jniDir -Force | Out-Null
            Copy-Item -LiteralPath $ksud -Destination (Join-Path $jniDir "libksud.so") -Force
            Write-Step "Embedded ksud (arm64-v8a) -> app/src/main/jniLibs/arm64-v8a/libksud.so"

            $ksudX86 = Join-Path $script:RepoRoot "target\x86_64-linux-android\release\ksud"
            if (Test-Path $ksudX86) {
                $jniDirX86 = Join-Path $script:ManagerDir "app\src\main\jniLibs\x86_64"
                New-Item -ItemType Directory -Path $jniDirX86 -Force | Out-Null
                Copy-Item -LiteralPath $ksudX86 -Destination (Join-Path $jniDirX86 "libksud.so") -Force
                Write-Step "Embedded ksud (x86_64) -> app/src/main/jniLibs/x86_64/libksud.so"
            }
            return
        }
    }

    $existing = Join-Path $script:ManagerDir "app\src\main\jniLibs\arm64-v8a\libksud.so"
    if (Test-Path $existing) {
        Write-Step "Using existing ksud at app/src/main/jniLibs/arm64-v8a/libksud.so"
        return
    }

    Write-Warning "No ksud binary found. The APK will not embed the ksud daemon. Use -UseOfficialKsud (original ksud), -BuildKsud, or -KsudBinary <path>."
}

function Resolve-Ndk([string]$sdk) {
    $ndkRoot = Join-Path $sdk "ndk"
    if (Test-Path $ndkRoot) {
        $ndk = Get-ChildItem $ndkRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($ndk) { return $ndk.FullName }
    }
    $bundle = Join-Path $sdk "ndk-bundle"
    if (Test-Path $bundle) { return $bundle }
    throw "Android NDK not found under $sdk"
}

function Build-KsudFromSource([string]$sdk) {
    Write-Step "Building ksud daemon (arm64-v8a + x86_64, API 26)..."
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        throw "cargo not found. Install Rust to build ksud, or use -UseOfficialKsud instead."
    }

    Ensure-OfficialAssets

    $ndk = Resolve-Ndk $sdk
    $llvmBin = Join-Path $ndk "toolchains\llvm\prebuilt\windows-x86_64\bin"
    if (-not (Test-Path (Join-Path $llvmBin "clang.exe"))) {
        throw "Unsupported NDK layout: $ndk"
    }
    $env:ANDROID_NDK_HOME = $ndk
    $env:ANDROID_NDK_ROOT = $ndk
    $env:LIBCLANG_PATH = $llvmBin
    $env:PATH = "$llvmBin;$env:PATH"

    Push-Location (Join-Path $script:RepoRoot "userspace\ksud")
    try {
        cargo ndk -t arm64-v8a -t x86_64 --platform 26 build --release
        if ($LASTEXITCODE -ne 0) { throw "cargo ndk failed with exit code $LASTEXITCODE" }
    }
    catch {
        throw "ksud build failed: $_"
    }
    finally {
        Pop-Location
    }

    $ksudArm = Join-Path $script:RepoRoot "target\aarch64-linux-android\release\ksud"
    $ksudX86 = Join-Path $script:RepoRoot "target\x86_64-linux-android\release\ksud"
    if (Test-Path $ksudArm) {
        $jniDir = Join-Path $script:ManagerDir "app\src\main\jniLibs\arm64-v8a"
        New-Item -ItemType Directory -Path $jniDir -Force | Out-Null
        Copy-Item -LiteralPath $ksudArm -Destination (Join-Path $jniDir "libksud.so") -Force
        Write-Step "Embedded built ksud (arm64-v8a) -> app/src/main/jniLibs/arm64-v8a/libksud.so"
    }
    if (Test-Path $ksudX86) {
        $jniDirX86 = Join-Path $script:ManagerDir "app\src\main\jniLibs\x86_64"
        New-Item -ItemType Directory -Path $jniDirX86 -Force | Out-Null
        Copy-Item -LiteralPath $ksudX86 -Destination (Join-Path $jniDirX86 "libksud.so") -Force
        Write-Step "Embedded built ksud (x86_64) -> app/src/main/jniLibs/x86_64/libksud.so"
    }
}

function Ensure-OfficialAssets {
    $binDir = Join-Path $script:RepoRoot "userspace\ksud\bin\aarch64"
    $needed = @(
        "android12-5.10_kernelsu.ko",
        "android13-5.10_kernelsu.ko",
        "android13-5.15_kernelsu.ko",
        "android14-5.15_kernelsu.ko",
        "android14-6.1_kernelsu.ko",
        "android15-6.6_kernelsu.ko",
        "android16-6.12_kernelsu.ko",
        "ksuinit"
    )
    $missing = @($needed | Where-Object { -not (Test-Path (Join-Path $binDir $_)) })
    $needsClean = $false
    if ($missing.Count -gt 0) {
        Write-Step "Fetching official LKM/ksuinit assets from KernelSU releases..."
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/tiann/KernelSU/releases/latest" `
            -Headers @{ "User-Agent" = "build-apk" }
        foreach ($name in $missing) {
            $asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if (-not $asset) { throw "Official KernelSU release does not contain asset: $name" }
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile (Join-Path $binDir $name) -UseBasicParsing
            Write-Step "Fetched $name"
        }
        $needsClean = $true
    }
    else {
        $binary = Join-Path $script:RepoRoot "target\aarch64-linux-android\release\ksud"
        if (Test-Path $binary) {
            $newest = $needed | ForEach-Object {
                Get-Item (Join-Path $binDir $_) | Select-Object -ExpandProperty LastWriteTime
            } | Sort-Object -Descending | Select-Object -First 1
            if ($newest -gt (Get-Item $binary).LastWriteTime) { $needsClean = $true }
        }
    }

    if ($needsClean) {
        Write-Step "Embedded assets changed; cleaning ksud for a fresh rebuild."
        Push-Location (Join-Path $script:RepoRoot "userspace\ksud")
        try {
            cargo clean -p ksud
        }
        finally {
            Pop-Location
        }
    }
}

function Get-OfficialKsud {
    Write-Step "Downloading the latest official KernelSU release..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/tiann/KernelSU/releases/latest" `
        -Headers @{ "User-Agent" = "build-apk" }
    $asset = $release.assets | Where-Object { $_.name -like "*release.apk" } | Select-Object -First 1
    if (-not $asset) { throw "No manager APK asset found in release $($release.tag_name)" }

    $apkPath = Join-Path $env:TEMP "KernelSU_official_$($release.tag_name).apk"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $apkPath -UseBasicParsing

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($apkPath)
    try {
        foreach ($abi in @("arm64-v8a", "x86_64")) {
            $entry = $zip.GetEntry("lib/$abi/libksud.so")
            if ($entry) {
                $dir = Join-Path $script:ManagerDir "app\src\main\jniLibs\$abi"
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                    $entry,
                    (Join-Path $dir "libksud.so"),
                    $true
                )
                Write-Step "Embedded official ksud ($abi) from $($release.tag_name)"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Clear-StaleNativeCache([string]$sdk) {
    $cxx = Join-Path $script:ManagerDir "app\.cxx"
    if (-not (Test-Path $cxx)) { return }
    $matchesSdk = Get-ChildItem $cxx -Recurse -File -ErrorAction SilentlyContinue |
        Select-String -SimpleMatch $sdk -List | Select-Object -First 1
    if ($matchesSdk) { return }
    $hasSdkRef = Get-ChildItem $cxx -Recurse -File -ErrorAction SilentlyContinue |
        Select-String -Pattern "android-sdk|Android\\Sdk" -List | Select-Object -First 1
    if ($hasSdkRef) {
        Write-Step "Native build cache points to a different SDK path; clearing app/.cxx."
        [System.IO.Directory]::Delete($cxx, $true)
    }
}

function Invoke-GradleBuild {
    $gradlewName = if ($script:IsWindows) { "gradlew.bat" } else { "gradlew" }
    $gradlew = Join-Path $script:ManagerDir $gradlewName
    if (-not (Test-Path $gradlew)) { throw "Gradle wrapper not found: $gradlew" }

    $task = "assemble$Variant"
    $gradleArgs = @()
    if ($Sign) {
        $signing = Initialize-Signing
        $gradleArgs += "-PKEYSTORE_FILE=$($signing.Keystore)"
        $gradleArgs += "-PKEYSTORE_PASSWORD=$($signing.KeystorePassword)"
        $gradleArgs += "-PKEY_ALIAS=$($signing.KeyAlias)"
        $gradleArgs += "-PKEY_PASSWORD=$($signing.KeyPassword)"
    }
    Push-Location $script:ManagerDir
    try {
        Clear-StaleNativeCache -sdk $sdk
        if ($SkipClean) {
            & $gradlew @gradleArgs $task --console=plain
        }
        else {
            & $gradlew @gradleArgs "clean" $task --console=plain
        }
        if ($LASTEXITCODE -ne 0) { throw "Gradle build failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

function Initialize-Signing {
    $store = if ($Keystore) { $Keystore } else { Join-Path $script:ManagerDir "ksu-custom.jks" }
    $storePass = if ($KeystorePassword) { $KeystorePassword } else { "kernelsu" }
    $alias = if ($KeyAlias) { $KeyAlias } else { "ksu" }
    $keyPass = if ($KeyPassword) { $KeyPassword } else { $storePass }

    if (-not (Test-Path $store)) {
        Write-Step "Generating signing keystore: $store"
        & keytool -genkeypair -alias $alias -keyalg RSA -keysize 2048 -validity 10000 `
            -storepass $storePass -keypass $keyPass -dname "CN=KernelSU Custom Manager" `
            -storetype JKS -keystore $store
        if ($LASTEXITCODE -ne 0) { throw "keytool failed to generate $store" }
    }

    $certDer = Join-Path $env:TEMP "ksu-custom-cert.der"
    & keytool -exportcert -alias $alias -keystore $store -storepass $storePass -file $certDer
    if ($LASTEXITCODE -ne 0) { throw "keytool failed to export the signing certificate" }

    $size = (Get-Item $certDer).Length
    $hash = (Get-FileHash $certDer -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host ""
    Write-Host "Custom manager signature - rebuild kernelsu.ko with these values:" -ForegroundColor Yellow
    Write-Host ("  KSU_EXPECTED_SIZE2 = 0x{0:x4}" -f $size) -ForegroundColor Yellow
    Write-Host ("  KSU_EXPECTED_HASH2 = {0}" -f $hash) -ForegroundColor Yellow
    Write-Host ""

    return [pscustomobject]@{
        Keystore = $store
        KeystorePassword = $storePass
        KeyAlias = $alias
        KeyPassword = $keyPass
    }
}

function Get-ApkOutput {
    $outDir = Join-Path $script:ManagerDir "app\build\outputs\apk\$($Variant.ToLowerInvariant())"
    $apk = Get-ChildItem $outDir -Filter "*.apk" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apk) { throw "Build succeeded but no APK was found under $outDir" }
    return $apk.FullName
}

try {
    Write-Step "Resolving JDK..."
    $jdk = Resolve-Jdk
    $env:JAVA_HOME = $jdk
    Write-Host "       JAVA_HOME = $jdk"

    Write-Step "Resolving Android SDK..."
    $sdk = Resolve-Sdk
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
    Write-Host "       ANDROID_HOME = $sdk"

    # Prefer IPv4 for dependency downloads; avoids TLS handshake issues on some networks.
    $env:GRADLE_OPTS = "-Djava.net.preferIPv4Stack=true"

    Repair-Uapi
    Prepare-Ksud
    Invoke-GradleBuild

    $apk = Get-ApkOutput
    Write-Step "APK ready: $apk"
    Write-Host ""
    Write-Host "Install with: adb install -r `"$apk`"" -ForegroundColor Green

    if ($Sign) {
        $apksigner = Get-ChildItem (Join-Path $sdk "build-tools") -Recurse -Filter "apksigner.bat" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($apksigner) {
            $certs = & $apksigner.FullName verify --print-certs $apk 2>&1
            $certHash = $certs | Select-String -Pattern "certificate SHA-256 digest" | Select-Object -First 1
            if ($certHash) { Write-Host "APK $($certHash.Line.Trim())" -ForegroundColor Yellow }
        }
    }
}
finally {
    Restore-Uapi
}
