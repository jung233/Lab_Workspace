$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$app = Join-Path $workspace 'apps/lab_workspace'
$flutter = if ($env:FLUTTER_BIN) { $env:FLUTTER_BIN } else { Join-Path $workspace '.tooling/flutter/flutter/bin/flutter.bat' }

if (-not (Test-Path -LiteralPath $flutter)) { throw "Flutter not found: $flutter. Set FLUTTER_BIN to Flutter 3.47.7." }
$version = (& $flutter --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $version -notmatch 'Flutter 3\.47\.7') { throw 'This release script requires Flutter 3.47.7.' }
Push-Location $app
try { & $flutter build windows --release; if ($LASTEXITCODE -ne 0) { throw 'Windows release packaging failed.' } }
finally { Pop-Location }
Write-Host 'Built an unpackaged Windows executable. Configure an organization-owned MSIX identity and signing certificate before distribution.'
