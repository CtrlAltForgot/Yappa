[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "preflight",
        "install",
        "start",
        "stop",
        "status",
        "logs",
        "backup",
        "restore",
        "verify",
        "upgrade",
        "rollback",
        "uninstall",
        "help"
    )]
    [string]$Command = "help"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ManifestPath = Join-Path $PSScriptRoot "install-manifest.json"

function Show-Usage {
    @"
Usage:
  .\Install-Yappa.ps1 preflight

The Windows lifecycle wrapper is intentionally preflight-only in this
development release. Installation remains disabled until the manifest has a
signed server bundle and the Windows 11/Windows Server conformance matrices
pass. Yappa never asks for or stores a remote Administrator password.
"@
}

function Read-InstallManifest {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Yappa install manifest is missing: $ManifestPath"
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw |
        ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.product -ne "Yappa Server") {
        throw "Unsupported or malformed Yappa install manifest."
    }
    return $manifest
}

function Test-Executable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Output ("ok      {0}" -f $Name)
        return $true
    }
    Write-Output ("missing {0}" -f $Name)
    return $false
}

function Invoke-Preflight {
    $manifest = Read-InstallManifest
    $failed = $false

    if ([Environment]::Is64BitOperatingSystem) {
        Write-Output "ok      x86_64 operating system"
    } else {
        Write-Output "blocked 64-bit Windows is required"
        $failed = $true
    }

    foreach ($executable in @("docker", "wsl.exe", "powershell.exe")) {
        if (-not (Test-Executable -Name $executable)) {
            $failed = $true
        }
    }

    if ($null -ne (Get-Command "docker" -ErrorAction SilentlyContinue)) {
        & docker compose version *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "ok      docker compose v2"
        } else {
            Write-Output "missing docker compose v2"
            $failed = $true
        }
    }

    if ($null -ne (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
        $wslStatus = (& wsl.exe --status 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $wslStatus -match "2") {
            Write-Output "ok      WSL 2"
        } else {
            Write-Output "blocked WSL 2 is not confirmed"
            $failed = $true
        }
    }

    $windowsTarget = $manifest.supportTargets |
        Where-Object { $_.id -eq "windows-11-wsl2-x64" }
    if ($windowsTarget.validation -ne "verified-release") {
        Write-Output "pending Windows release conformance is not complete"
    }
    if (-not $manifest.release.published) {
        Write-Output "pending no signed Yappa server release is published"
    }

    if ($failed) {
        throw "Yappa Windows server preflight failed."
    }
    Write-Output "Yappa Windows prerequisite preflight passed."
    Write-Output "Installation remains disabled until release validation passes."
}

switch ($Command) {
    "help" {
        Show-Usage
    }
    "preflight" {
        Invoke-Preflight
    }
    default {
        [void](Read-InstallManifest)
        throw "The '$Command' Windows lifecycle command is not implemented safely yet."
    }
}
