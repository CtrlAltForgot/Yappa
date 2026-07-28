param(
  [Parameter(Mandatory = $true)]
  [string]$SafeVersion
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$clientRoot = Join-Path $repositoryRoot "client"
$manifestPath = Join-Path $repositoryRoot ".github/release-versions.json"
$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
$diagnostics = Join-Path $repositoryRoot ".artifacts/diagnostics/windows"
New-Item -ItemType Directory -Force -Path $diagnostics | Out-Null
$temporaryRoot = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
}
else {
  [IO.Path]::GetTempPath()
}

$archive = Join-Path $temporaryRoot (
  "libsodium-{0}-msvc.zip" -f $manifest.libsodium.version
)
$extract = Join-Path $temporaryRoot "yappa-libsodium"
Invoke-WebRequest -Uri $manifest.libsodium.url -OutFile $archive
$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
$expected = $manifest.libsodium.sha256.ToLowerInvariant()
if ($actual -ne $expected) {
  throw "libsodium archive checksum mismatch"
}
if (Test-Path $extract) {
  Remove-Item -Recurse -Force $extract
}
Expand-Archive -Path $archive -DestinationPath $extract
$runtime = Join-Path $extract "libsodium/x64/Release/v143/dynamic"
$sodiumDll = Join-Path $runtime "libsodium.dll"
if (-not (Test-Path $sodiumDll)) {
  throw "libsodium.dll was not present in the verified archive"
}
$env:Path = "$runtime;$env:Path"

Push-Location $clientRoot
try {
  flutter pub get --enforce-lockfile
  flutter build windows --release `
    --split-debug-info=build/windows-symbols 2>&1 |
    Tee-Object -FilePath (Join-Path $diagnostics "flutter-build.log")
  if ($LASTEXITCODE -ne 0) {
    throw "Flutter Windows release build failed"
  }
}
finally {
  Pop-Location
}

$bundle = Join-Path $clientRoot "build/windows/x64/runner/Release"
Copy-Item -Force $sodiumDll (Join-Path $bundle "libsodium.dll")
foreach ($file in @(
  "yappa.exe",
  "flutter_windows.dll",
  "yappa_mls.dll",
  "libsodium.dll"
)) {
  if (-not (Test-Path (Join-Path $bundle $file))) {
    throw "Required Windows runtime file is missing: $file"
  }
}

$forbidden = [regex]::new(
  '(?i)([A-Z]:\\Users\\|/Users/|/home/|sslip\.io|codex-yappa|' +
  'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY)'
)
foreach ($artifact in Get-ChildItem -Path $bundle -Recurse -File) {
  $content = [Text.Encoding]::Latin1.GetString(
    [IO.File]::ReadAllBytes($artifact.FullName)
  )
  if ($forbidden.IsMatch($content)) {
    throw (
      "Forbidden builder path, secret, or retired transport marker in " +
      "Windows bundle: $($artifact.Name)"
    )
  }
}

Copy-Item `
  (Join-Path $repositoryRoot ".github/templates/README-Windows.txt") `
  (Join-Path $bundle "README-Windows.txt")

$executable = Resolve-Path (Join-Path $bundle "yappa.exe")
$process = Start-Process `
  -FilePath $executable `
  -RedirectStandardOutput (Join-Path $diagnostics "smoke.stdout.log") `
  -RedirectStandardError (Join-Path $diagnostics "smoke.stderr.log") `
  -PassThru
Start-Sleep -Seconds 8
if ($process.HasExited) {
  throw (
    "Yappa exited during the Windows runtime smoke test " +
    "(exit code $($process.ExitCode))"
  )
}
Stop-Process -Id $process.Id -Force
Wait-Process -Id $process.Id -ErrorAction SilentlyContinue

$dist = Join-Path $clientRoot "dist"
$output = Join-Path $dist "Yappa-$SafeVersion-windows-x64.zip"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path $output) {
  Remove-Item -Force $output
}
Compress-Archive -Path (Join-Path $bundle "*") -DestinationPath $output
