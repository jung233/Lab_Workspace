$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$app = Join-Path $workspace 'apps/lab_workspace'
$flutter = if ($env:FLUTTER_BIN) { $env:FLUTTER_BIN } else { Join-Path $workspace '.tooling/flutter/flutter/bin/flutter.bat' }

if (-not (Test-Path -LiteralPath $flutter)) { throw "Flutter not found: $flutter. Set FLUTTER_BIN to Flutter 3.47.7." }
$version = (& $flutter --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $version -notmatch 'Flutter 3\.47\.7') { throw 'This release script requires Flutter 3.47.7.' }
foreach ($name in @('LAB_WORKSPACE_UPLOAD_STORE_FILE','LAB_WORKSPACE_UPLOAD_STORE_PASSWORD','LAB_WORKSPACE_UPLOAD_KEY_ALIAS','LAB_WORKSPACE_UPLOAD_KEY_PASSWORD')) {
  if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Missing release signing variable: $name" }
}
Push-Location $app
try { & $flutter build appbundle --release; if ($LASTEXITCODE -ne 0) { throw 'Android App Bundle packaging failed.' } }
finally { Pop-Location }
