param([ValidateSet('android', 'host', 'all')][string]$Platform = 'all')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$toolDir = @("$root/.tools", "$root/../ReplicaMusic/.tools") |
    Where-Object { Test-Path "$_/cargo/bin/cargo.exe" } | Select-Object -First 1
if ($toolDir) {
    $toolDir = (Resolve-Path $toolDir).Path
    $env:CARGO_HOME = Join-Path $toolDir 'cargo'
    $env:RUSTUP_HOME = Join-Path $toolDir 'rustup'
    $env:ANDROID_HOME = Join-Path $toolDir 'android-sdk'
    $env:ANDROID_NDK_HOME = Join-Path $toolDir 'android-sdk\ndk\28.2.13676358'
    $env:PATH = "$toolDir\cargo\bin;$toolDir\mingw64\bin;$env:PATH"
}

Push-Location $root
try {
    if ($Platform -eq 'host' -or $Platform -eq 'all') {
        cargo build
        if ($LASTEXITCODE -ne 0) { throw 'Rust host build failed' }
    }
    if ($Platform -eq 'android' -or $Platform -eq 'all') {
        $ndkBin = Join-Path $env:ANDROID_NDK_HOME 'toolchains\llvm\prebuilt\windows-x86_64\bin'
        if (!(Test-Path -LiteralPath $ndkBin)) { throw "Android NDK not found: $ndkBin" }
        $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = Join-Path $ndkBin 'aarch64-linux-android28-clang.cmd'
        $env:CC_aarch64_linux_android = $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
        $env:AR_aarch64_linux_android = Join-Path $ndkBin 'llvm-ar.exe'
        $env:CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER = Join-Path $ndkBin 'x86_64-linux-android28-clang.cmd'
        $env:CC_x86_64_linux_android = $env:CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER
        $env:AR_x86_64_linux_android = Join-Path $ndkBin 'llvm-ar.exe'
        foreach ($target in @('aarch64-linux-android', 'x86_64-linux-android')) {
            cargo build --lib --release --target $target
            if ($LASTEXITCODE -ne 0) { throw "Rust Android build failed: $target" }
            $abi = if ($target -eq 'aarch64-linux-android') { 'arm64-v8a' } else { 'x86_64' }
            $dest = Join-Path $root "apps\replica\android\app\src\main\jniLibs\$abi"
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -LiteralPath "target\$target\release\libreplica_music_core.so" -Destination $dest -Force
        }
    }
} finally {
    Pop-Location
}
