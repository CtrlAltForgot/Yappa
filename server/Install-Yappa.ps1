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
        "verify-backup",
        "upgrade",
        "rollback",
        "uninstall",
        "recover",
        "help"
    )]
    [string]$Command = "help",

    [string]$Distribution,
    [string]$InstallDirectory,
    [string]$LocalBundle,
    [string]$Sha256,
    [string]$Backup,
    [string]$PreserveData,
    [switch]$Lan,
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ManifestPath = Join-Path $PSScriptRoot "install-manifest.json"
$LinuxInstallerPath = Join-Path $PSScriptRoot "install-yappa.sh"

function Show-Usage {
    @"
Usage:
  .\Install-Yappa.ps1 preflight [-Distribution NAME]
  .\Install-Yappa.ps1 install -LocalBundle ARCHIVE -Sha256 DIGEST `
    -InstallDirectory /absolute/wsl/path [-Lan] [-NoStart]
  .\Install-Yappa.ps1 start -InstallDirectory /absolute/wsl/path [-Lan]
  .\Install-Yappa.ps1 stop|status|logs|verify|recover `
    -InstallDirectory /absolute/wsl/path
  .\Install-Yappa.ps1 backup -InstallDirectory /absolute/wsl/path `
    -Backup WINDOWS_OR_WSL_PATH
  .\Install-Yappa.ps1 verify-backup -Backup WINDOWS_OR_WSL_PATH
  .\Install-Yappa.ps1 restore -Backup WINDOWS_OR_WSL_PATH `
    -LocalBundle ARCHIVE -Sha256 DIGEST `
    -InstallDirectory /absolute/new/wsl/path
  .\Install-Yappa.ps1 upgrade -InstallDirectory /absolute/wsl/path `
    -LocalBundle ARCHIVE -Sha256 DIGEST -Backup WINDOWS_OR_WSL_PATH
  .\Install-Yappa.ps1 rollback -InstallDirectory /absolute/wsl/path `
    -Backup WINDOWS_OR_WSL_PATH
  .\Install-Yappa.ps1 uninstall -InstallDirectory /absolute/wsl/path `
    -Backup WINDOWS_OR_WSL_PATH -PreserveData /absolute/new/wsl/path

This development wrapper runs Yappa's canonical Linux lifecycle inside one
explicit WSL2 distribution. Bundle, checksum, backup, restore, upgrade,
rollback, and uninstall safety remain enforced by the shared installer.
Windows service registration and Windows Firewall mutation remain disabled
until their native conformance contracts pass.
Yappa never asks for or stores a remote Administrator password.
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

function Get-WslPrefix {
    $prefix = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $prefix.Add("--distribution")
        $prefix.Add($Distribution)
    }
    $prefix.Add("--")
    return $prefix
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$Capture
    )

    if ($null -eq (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
        throw "WSL is required. Install WSL2 and one supported Linux distribution."
    }

    $allArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (Get-WslPrefix)) {
        $allArguments.Add($item)
    }
    foreach ($item in $Arguments) {
        $allArguments.Add($item)
    }

    if ($Capture) {
        $output = & wsl.exe @allArguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed with exit code $LASTEXITCODE."
        }
        return ($output | Out-String).Trim()
    }

    & wsl.exe @allArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Yappa WSL lifecycle command failed with exit code $LASTEXITCODE."
    }
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "A non-empty path is required."
    }
    if ($Path.StartsWith("/")) {
        return $Path
    }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    return Invoke-Wsl -Arguments @("wslpath", "-a", "--", $resolved) -Capture
}

function Assert-LinuxInstallDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$New
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not $Path.StartsWith("/") -or
        $Path -eq "/") {
        throw "-InstallDirectory must be an absolute WSL Linux path other than /."
    }
    if ($Path.StartsWith("/mnt/", [StringComparison]::Ordinal)) {
        throw "-InstallDirectory must use the WSL Linux filesystem, not a Windows /mnt drive."
    }
    if ($New -and $Path.EndsWith("/")) {
        throw "A new install directory must not end with '/'."
    }
}

function Get-SourceInstallerPath {
    if (-not (Test-Path -LiteralPath $LinuxInstallerPath -PathType Leaf)) {
        throw "Canonical Linux installer is missing: $LinuxInstallerPath"
    }
    return ConvertTo-WslPath -Path $LinuxInstallerPath
}

function Get-InstalledInstallerPath {
    Assert-LinuxInstallDirectory -Path $InstallDirectory
    return "$InstallDirectory/install-yappa.sh"
}

function Require-Value {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required for '$Command'."
    }
}

function Add-PathArgument {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Flag,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $Arguments.Add($Flag)
    $Arguments.Add((ConvertTo-WslPath -Path $Value))
}

function Invoke-LinuxLifecycle {
    [void](Read-InstallManifest)

    if ($Command -eq "preflight") {
        Invoke-Wsl -Arguments @("bash", (Get-SourceInstallerPath), "preflight")
        return
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    $installer = if ($Command -in @("install", "restore", "verify-backup")) {
        Get-SourceInstallerPath
    } else {
        Get-InstalledInstallerPath
    }
    $arguments.Add("bash")
    $arguments.Add($installer)
    $arguments.Add($Command)

    switch ($Command) {
        "install" {
            Assert-LinuxInstallDirectory -Path $InstallDirectory -New
            Require-Value -Name "-LocalBundle" -Value $LocalBundle
            Require-Value -Name "-Sha256" -Value $Sha256
            Add-PathArgument -Arguments $arguments -Flag "--local-bundle" -Value $LocalBundle
            $arguments.Add("--sha256")
            $arguments.Add($Sha256)
            $arguments.Add("--install-dir")
            $arguments.Add($InstallDirectory)
            if ($Lan) { $arguments.Add("--lan") }
            if ($NoStart) { $arguments.Add("--no-start") }
        }
        "start" {
            if ($Lan) { $arguments.Add("--lan") }
        }
        "backup" {
            Require-Value -Name "-Backup" -Value $Backup
            $arguments.Add((ConvertTo-WslPath -Path $Backup))
        }
        "verify-backup" {
            Require-Value -Name "-Backup" -Value $Backup
            $arguments.Add((ConvertTo-WslPath -Path $Backup))
        }
        "restore" {
            Assert-LinuxInstallDirectory -Path $InstallDirectory -New
            Require-Value -Name "-Backup" -Value $Backup
            Require-Value -Name "-LocalBundle" -Value $LocalBundle
            Require-Value -Name "-Sha256" -Value $Sha256
            Add-PathArgument -Arguments $arguments -Flag "--backup" -Value $Backup
            Add-PathArgument -Arguments $arguments -Flag "--local-bundle" -Value $LocalBundle
            $arguments.Add("--sha256")
            $arguments.Add($Sha256)
            $arguments.Add("--install-dir")
            $arguments.Add($InstallDirectory)
        }
        "upgrade" {
            Require-Value -Name "-LocalBundle" -Value $LocalBundle
            Require-Value -Name "-Sha256" -Value $Sha256
            Require-Value -Name "-Backup" -Value $Backup
            Add-PathArgument -Arguments $arguments -Flag "--local-bundle" -Value $LocalBundle
            $arguments.Add("--sha256")
            $arguments.Add($Sha256)
            Add-PathArgument -Arguments $arguments -Flag "--backup" -Value $Backup
        }
        "rollback" {
            Require-Value -Name "-Backup" -Value $Backup
            Add-PathArgument -Arguments $arguments -Flag "--backup" -Value $Backup
        }
        "uninstall" {
            Require-Value -Name "-Backup" -Value $Backup
            Require-Value -Name "-PreserveData" -Value $PreserveData
            Assert-LinuxInstallDirectory -Path $PreserveData -New
            Add-PathArgument -Arguments $arguments -Flag "--backup" -Value $Backup
            $arguments.Add("--preserve-data")
            $arguments.Add($PreserveData)
        }
    }

    Invoke-Wsl -Arguments $arguments.ToArray()
}

switch ($Command) {
    "help" {
        Show-Usage
    }
    default {
        Invoke-LinuxLifecycle
    }
}
