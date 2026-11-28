param([ValidateSet('debug', 'release')][string]$Mode = 'release')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$toolDir = @("$root/.tools", "$root/../ReplicaMusic/.tools") |
    Where-Object { Test-Path "$_/flutter/bin/flutter.bat" } | Select-Object -First 1
if ($toolDir -and !(Get-Command flutter -ErrorAction SilentlyContinue)) {
    $toolDir = (Resolve-Path $toolDir).Path
    $env:PATH = "$toolDir/flutter/bin;$env:PATH"
    $env:JAVA_HOME = "$toolDir/jdk-21"
    $env:ANDROID_HOME = "$toolDir/android-sdk"
    $env:ANDROID_NDK_ROOT = "$toolDir/android-sdk/ndk/28.2.13676358"
    $env:GRADLE_USER_HOME = "$toolDir/gradle"
    $env:PUB_CACHE = "$toolDir/pub-cache"
    if (Test-Path "$toolDir/mingw64/bin") { $env:MINGW_HOME = "$toolDir/mingw64" }
}
if (!(Get-Command cmake -ErrorAction SilentlyContinue)) {
    $cmakeDir = @(
        "$env:ANDROID_HOME/cmake/*/bin",
        "$env:LOCALAPPDATA/Android/Sdk/cmake/*/bin"
    ) | ForEach-Object { Get-Item $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($cmakeDir) { $env:PATH = "$($cmakeDir.FullName);$env:PATH" }
}
$env:CMAKE_GENERATOR = 'Ninja'

$ffmpegTargets = @(
    @('arm64-v8a', 'ffmpeg-android-arm64-v8a.so', '6ebf95cf17e81da68a2afad1703712a3b84eb0a8d893ed7478145c9b0df09000'),
    @('x86_64', 'ffmpeg-android-x86_64.so', 'd2e949b18cbf25c58f5739d9b5b55a33b0916e2f5b3954751e4b9cc9a10676d3')
)
foreach ($t in $ffmpegTargets) {
    $abi = $t[0]; $asset = $t[1]; $expectedHash = $t[2]
    $destDir = Join-Path $root "apps/replica/android/app/src/main/jniLibs/$abi"
    $destFile = Join-Path $destDir 'libffmpeg.so'
    if (!(Test-Path -LiteralPath $destFile) -or
        (Get-FileHash $destFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        $url = "https://github.com/ymusic-io/ffmpeg-build/releases/download/n9.1-dev-18-g90cca8111b/$asset"
        Invoke-WebRequest -Uri $url -OutFile $destFile
        $actualHash = (Get-FileHash $destFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            Remove-Item -LiteralPath $destFile -Force
            throw "SHA-256 mismatch for $asset ($actualHash)"
        }
    }
}

function Invoke-Checked($command, [string[]]$arguments) {
    & $command @arguments
    if ($LASTEXITCODE -ne 0) { throw "$command $arguments failed ($LASTEXITCODE)" }
}

Push-Location "$root/apps/replica"
try {
    Invoke-Checked flutter @('pub', 'get')
    Invoke-Checked dart @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test')
    Invoke-Checked flutter @('analyze')
    Invoke-Checked flutter @('test')
    Invoke-Checked flutter @('build', 'apk', "--$Mode", '--target-platform', 'android-arm64,android-x64')

    $versionLine = Select-String '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$' pubspec.yaml
    if (!$versionLine) { throw 'Expected version MAJOR.MINOR.PATCH+BUILD in pubspec.yaml' }
    $version = $versionLine.Matches[0].Groups[1].Value
    $buildNumber = $versionLine.Matches[0].Groups[2].Value
    $apk = "build/app/outputs/flutter-apk/app-$Mode.apk"
    $sdkLine = Select-String '^sdk\.dir=(.+)$' android/local.properties
    $sdk = $sdkLine.Matches[0].Groups[1].Value.Replace('\\', '\').Replace('\:', ':')
    $aapt = Get-ChildItem "$sdk/build-tools/*/aapt.exe" |
        Where-Object { $_.Directory.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1
    if (!$aapt) { throw 'Android SDK Build Tools (aapt.exe) missing' }
    $badging = & $aapt.FullName dump badging $apk
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect APK' }
    $identity = $badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1
    if ($Mode -eq 'release') {
        $signatures = & (Join-Path $aapt.DirectoryName 'apksigner.bat') verify --print-certs $apk
        $fingerprint = '4b61423c90f3781d8f9b52ebbe80efb7412dafb9bc0175fdbf31223cbcdf5cd0'
        if ($LASTEXITCODE -ne 0 -or $signatures -notcontains "Signer #1 certificate SHA-256 digest: $fingerprint") {
            throw 'Release APK signing certificate mismatch'
        }
    }
    if (!$identity -or !$identity.Contains("name='io.replicamedia.replica'") -or
        !$identity.Contains("versionName='$version'") -or !$identity.Contains("versionCode='$buildNumber'")) {
        throw "Unexpected APK identity: $identity"
    }
    $dest = Join-Path $root 'dist'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $name = "Replica-$version-$Mode.apk"
    Copy-Item -LiteralPath $apk -Destination "$dest/$name"
    $hash = (Get-FileHash "$dest/$name" -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$dest/$name.sha256" -Value "$hash  $name" -Encoding Ascii
    Write-Output "$dest/$name"
} finally {
    Pop-Location
}
