param([Parameter(Mandatory)][string]$NotesFile)

$ErrorActionPreference = 'Stop'
$notes = (Resolve-Path -LiteralPath $NotesFile).Path
$root = Split-Path $PSScriptRoot -Parent
$repo = 'tyt0815/Replica'
function Invoke-Gh([string[]]$Arguments) {
    & gh @Arguments
    if ($LASTEXITCODE) { throw "GitHub CLI failed: $($Arguments[0])" }
}
Push-Location $root
try {
    if (!(Get-Command gh -ErrorAction SilentlyContinue)) {
        $candidate = "$root/../ReplicaMusic/.tools/gh/bin"
        if (Test-Path "$candidate/gh.exe") { $env:PATH = "$candidate;$env:PATH" }
    }
    $changes = git status --porcelain
    if ($LASTEXITCODE -or $changes) { throw 'Release needs a clean working tree' }
    $head = git rev-parse HEAD
    $remote = git ls-remote origin refs/heads/main
    if ($LASTEXITCODE -or !("$remote".StartsWith("$head`t"))) { throw 'Push the tested commit to main first' }
    $version = (Select-String '^version:\s*(\d+\.\d+\.\d+)\+' apps/replica/pubspec.yaml).Matches[0].Groups[1].Value
    $tag = "v$version"
    $file = "Replica-$version-release.apk"
    & "$PSScriptRoot/check-android.ps1"
    $existing = Invoke-Gh @('release','list','--repo',$repo,'--limit','100','--json','tagName,isDraft') | ConvertFrom-Json
    $release = $existing | Where-Object tagName -eq $tag
    if ($release -and !$release.isDraft) { throw "$tag already published" }
    $tagRef = git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}"
    if ($LASTEXITCODE) { throw 'Cannot read remote tags' }
    if ($tagRef) {
        if (($tagRef -join "`n") -notmatch "(?m)^$head\s") { throw 'Tag points to another commit' }
    } else {
        git push origin "${head}:refs/tags/$tag"
        if ($LASTEXITCODE) { throw 'Tag push failed' }
    }
    if (!$release) {
        Invoke-Gh @('release','create',$tag,'--repo',$repo,'--verify-tag','--draft','--title',"Replica $version",'--notes-file',$notes)
    }
    Invoke-Gh @('release','upload',$tag,"dist/$file","dist/$file.sha256",'--repo',$repo,'--clobber')
    $expected = (Get-FileHash "dist/$file").Hash.ToLowerInvariant()
    function Confirm-Assets {
        $temp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString()))
        try {
            Invoke-Gh @('release','download',$tag,'--repo',$repo,'--pattern',$file,'--pattern',"$file.sha256",'--dir',$temp.FullName)
            if ((Get-FileHash "$temp/$file").Hash -ne $expected -or
                (Get-Content "$temp/$file.sha256") -ne "$expected  $file") { throw 'Uploaded assets do not match' }
        } finally {
            foreach ($asset in @($file,"$file.sha256")) {
                $path = Join-Path $temp.FullName $asset
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
            }
            [IO.Directory]::Delete($temp.FullName)
        }
    }
    Confirm-Assets
    Invoke-Gh @('release','edit',$tag,'--repo',$repo,'--draft=false','--latest','--notes-file',$notes)
    Confirm-Assets
    Invoke-Gh @('release','view',$tag,'--repo',$repo,'--json','url,tagName,isDraft')
} finally { Pop-Location }
