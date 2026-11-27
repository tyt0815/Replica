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
    $env:GRADLE_USER_HOME = "$toolDir/gradle"
    $env:PUB_CACHE = "$toolDir/pub-cache"
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

    $versionLine = Select-String '^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$' pubspec.yaml
    if (!$versionLine) { throw 'Expected version MAJOR.MINOR.PATCH+BUILD in pubspec.yaml' }
    $version = $versionLine.Matches[0].Groups[1].Value
    $dest = Join-Path $root 'dist'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $name = "Replica-$version-$Mode.apk"
    Copy-Item -LiteralPath "build/app/outputs/flutter-apk/app-$Mode.apk" -Destination "$dest/$name"
    $hash = (Get-FileHash "$dest/$name" -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$dest/$name.sha256" -Value "$hash  $name" -Encoding Ascii
    Write-Output "$dest/$name"
} finally {
    Pop-Location
}
