[CmdletBinding()]
param([string] $Version = '0.0.0')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$zip  = Join-Path $out "WinForge-$Version.zip"

# Never package a catalog the engine would refuse to run.
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'WinForge.ps1') ValidateCatalog -StateRoot (Join-Path ([IO.Path]::GetTempPath()) 'winforge-build-state')
if ($LASTEXITCODE -ne 0) { throw 'Catalog validation failed; not packaging.' }

$include = 'WinForge.ps1','WinForge.bat','Core','Adapters','Modules','UI','Catalog','README.md','LICENSE','CHANGELOG.md','SECURITY.md'
$stage = Join-Path $env:TEMP ("winforge-stage-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach ($i in $include) {
        $src = Join-Path $root $i
        if (-not (Test-Path -LiteralPath $src)) { throw "Missing release file: $i" }
        Copy-Item $src (Join-Path $stage $i) -Recurse -Force
    }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
"$hash  $(Split-Path -Leaf $zip)" | Set-Content (Join-Path $out 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Built $zip"
Write-Host "SHA256 $hash"
