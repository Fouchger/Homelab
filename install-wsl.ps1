# ==============================================================================
# Controlplane WSL Release Bootstrap
# Downloads, verifies and runs one exact public runtime release.
# ==============================================================================

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(-test\.[0-9]+)?$')]
    [string]$Release,

    [switch]$ApproveTemporaryBypass,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$InstallerArgument = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$githubRepository = 'Fouchger/Homelab'
$releaseChannel = 'test'

if (($releaseChannel -eq 'test') -and ($Release -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+-test\.[0-9]+$')) {
    throw 'The test branch accepts test releases only: vMAJOR.MINOR.PATCH-test.NUMBER'
}
if (($releaseChannel -eq 'stable') -and ($Release -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$')) {
    throw 'The main branch accepts stable releases only: vMAJOR.MINOR.PATCH'
}

$assetName = "controlplane-wsl-${Release}.zip"
$downloadRoot = "https://github.com/$githubRepository/releases/download/$Release"
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "controlplane-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    $assetPath = Join-Path $temporaryDirectory $assetName
    $checksumPath = "$assetPath.sha256"

    Write-Host "🚀 Downloading Controlplane $Release from the $releaseChannel channel" -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$downloadRoot/$assetName" -OutFile $assetPath -UseBasicParsing
    Invoke-WebRequest -Uri "$downloadRoot/$assetName.sha256" -OutFile $checksumPath -UseBasicParsing

    Write-Host '🔐 Verifying the SHA-256 checksum' -ForegroundColor Cyan
    $expectedHash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -cne $expectedHash) {
        throw "Checksum validation failed for $assetName."
    }

    Expand-Archive -LiteralPath $assetPath -DestinationPath $temporaryDirectory -Force
    $installerPath = Join-Path $temporaryDirectory 'controlplane-platform\bin\controlplane-wsl.ps1'

    # A Group Policy has higher precedence than Process scope or the
    # powershell.exe -ExecutionPolicy option. An unsigned runtime cannot safely
    # continue when Group Policy permits only signed scripts or no scripts.
    $machinePolicy = Get-ExecutionPolicy -Scope MachinePolicy
    $userPolicy = Get-ExecutionPolicy -Scope UserPolicy
    $managedPolicy = if ($machinePolicy -ne 'Undefined') {
        $machinePolicy
    }
    elseif ($userPolicy -ne 'Undefined') {
        $userPolicy
    }
    else {
        $null
    }

    if ($managedPolicy -in @('Restricted', 'AllSigned')) {
        throw @"
Windows Group Policy enforces the '$managedPolicy' execution policy. Neither
an elevated account nor a process-only bypass can override that policy. Ask
your administrator to allow local scripts and remote signed scripts, then run
the installer again. Use 'Get-ExecutionPolicy -List' to review every scope.
"@
    }

    # The archive has already passed SHA-256 verification. Remove any Windows
    # Internet Zone marker from its PowerShell files so a managed RemoteSigned
    # policy can allow the verified local copy without weakening that policy.
    Get-ChildItem -LiteralPath $temporaryDirectory -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') } |
        ForEach-Object { Unblock-File -LiteralPath $_.FullName }

    if (-not $ApproveTemporaryBypass) {
        Write-Host ''
        Write-Host 'The release checksum is valid.' -ForegroundColor Green
        Write-Host 'Controlplane will start a separate PowerShell process with' -ForegroundColor Yellow
        Write-Host 'ExecutionPolicy Bypass. The bypass ends when that process exits.' -ForegroundColor Yellow
        $approval = Read-Host 'Continue with the temporary bypass? [y/N]'
        if ($approval -notmatch '^[Yy]') {
            throw 'Installation cancelled by the user.'
        }
    }

    Write-Host '🛠️ Starting the interactive WSL installer' -ForegroundColor Cyan
    $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    }
    else {
        Join-Path $PSHOME 'powershell.exe'
    }
    & $powerShellExecutable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installerPath @InstallerArgument
    if ($LASTEXITCODE -ne 0) {
        throw "The WSL installer exited with code $LASTEXITCODE."
    }

    Write-Host '✔ Controlplane WSL installation completed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
