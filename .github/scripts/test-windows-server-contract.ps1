[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$installer = Join-Path $repositoryRoot "server/Install-Yappa.ps1"
$global:YappaWslCalls = [System.Collections.Generic.List[object]]::new()

function global:wsl.exe {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Remaining)

    $arguments = @($Remaining | ForEach-Object { [string]$_ })
    $global:YappaWslCalls.Add($arguments)
    $global:LASTEXITCODE = 0
    if ($arguments -contains "wslpath") {
        $inputPath = $arguments[-1].Replace("\", "/")
        $leaf = [System.IO.Path]::GetFileName($inputPath)
        Write-Output "/mnt/c/contract/$leaf"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected error /$Pattern/, received: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected action to fail with /$Pattern/."
}

& $installer help | Out-Null
Assert-True ($global:YappaWslCalls.Count -eq 0) `
    "Help must not enter WSL."

& $installer preflight -Distribution "Ubuntu-24.04"
$preflight = $global:YappaWslCalls[-1]
Assert-True ($preflight[0] -eq "--distribution") `
    "An explicit distribution must be forwarded as a separate argument."
Assert-True ($preflight[1] -eq "Ubuntu-24.04") `
    "The selected distribution changed during dispatch."
Assert-True ($preflight -contains "preflight") `
    "Preflight must invoke the canonical Linux installer."

$global:YappaWslCalls.Clear()
$digest = "a" * 64
& $installer install `
    -Distribution "Ubuntu-24.04" `
    -LocalBundle "C:\Yappa contract\bundle;not-a-command.tar.gz" `
    -Sha256 $digest `
    -InstallDirectory "/home/yappa/Yappa Server" `
    -Lan `
    -NoStart

$install = $global:YappaWslCalls[-1]
Assert-True ($install -contains "--local-bundle") `
    "Install must forward the local-bundle contract."
Assert-True ($install -contains "/mnt/c/contract/bundle;not-a-command.tar.gz") `
    "A Windows bundle path must be converted and preserved as one argument."
Assert-True ($install -contains "/home/yappa/Yappa Server") `
    "The Linux install path must remain one argument."
Assert-True ($install -contains "--lan") "LAN mode was not forwarded."
Assert-True ($install -contains "--no-start") "No-start mode was not forwarded."
Assert-True (-not ($install -contains "-c")) `
    "Lifecycle dispatch must not build a shell command string."

$global:YappaWslCalls.Clear()
& $installer upgrade `
    -InstallDirectory "/home/yappa/Yappa Server" `
    -LocalBundle "C:\bundle.tar.gz" `
    -Sha256 $digest `
    -Backup "C:\Yappa backups\before upgrade.tar.gz.age"
$upgrade = $global:YappaWslCalls[-1]
$bashIndex = [Array]::IndexOf($upgrade, "bash")
Assert-True ($bashIndex -ge 0) "Upgrade must enter the canonical Bash installer."
Assert-True ($upgrade[$bashIndex + 1] -eq "/home/yappa/Yappa Server/install-yappa.sh") `
    "Installed lifecycle commands must target the selected installation."
Assert-True ($upgrade -contains "/mnt/c/contract/before upgrade.tar.gz.age") `
    "Backup paths with spaces must remain a single converted argument."

Assert-Throws {
    & $installer status -InstallDirectory "/mnt/c/Yappa"
} "WSL Linux filesystem"
Assert-Throws {
    & $installer install `
        -InstallDirectory "/home/yappa/server" `
        -Sha256 $digest
} "-LocalBundle"
Assert-Throws {
    & $installer uninstall `
        -InstallDirectory "/home/yappa/server" `
        -Backup "C:\backup.age" `
        -PreserveData "/mnt/c/preserved"
} "WSL Linux filesystem"

Write-Output "Windows server lifecycle bridge contract passed."
