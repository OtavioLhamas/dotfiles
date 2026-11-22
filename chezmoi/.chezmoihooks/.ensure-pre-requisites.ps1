# Runs during hooks.read-source-state.pre (CAN'T be a template)

$ErrorActionPreference = "Stop"

# Determine source directory for reading declarative files
$SourceDir = if ($env:CHEZMOI_SOURCE_DIR) { $env:CHEZMOI_SOURCE_DIR } else { Split-Path -Parent $PSScriptRoot }

# Non-interactive when running under the test harness, prompting otherwise.
$wingetNonInteractive = @()
if ($env:DOTFILES_TEST -eq "1") {
    $wingetNonInteractive = @("--disable-interactivity")
}

function Update-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath) -join ";"
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source
    )

    $listArgs = @("list", "--id", $Id, "--exact", "--accept-source-agreements", "--disable-interactivity")
    if ($Source) { $listArgs += @("--source", $Source) }
    $listOutput = & winget @listArgs 2>&1
    $listExitCode = $LASTEXITCODE
    $listText = $listOutput -join "`n"
    return ($listExitCode -eq 0 -and
        $listText -match [regex]::Escape($Id) -and
        $listText -notmatch "No installed package found")
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source
    )

    $installArgs = @("install", "--id", $Id, "--accept-source-agreements", "--accept-package-agreements", "--silent")
    if ($Source) { $installArgs += @("--source", $Source) }
    $installArgs += $wingetNonInteractive
    $installOutput = & winget @installArgs 2>&1
    $installExitCode = $LASTEXITCODE
    $installOutput | ForEach-Object { Write-Host $_ }

    if ($installExitCode -eq 0) { return }

    # WinGet returns 0x8A15002B (-1978335189) when the package is already
    # installed and there is no newer version. Confirm the installed state
    # rather than treating every nonzero result as success.
    if ($installExitCode -eq -1978335189 -and (Test-WingetPackageInstalled -Id $Id -Source $Source)) {
        Write-Host "$Id is already installed; no upgrade is available."
        return
    }

    throw "winget install $Id failed with exit code $installExitCode."
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "cannot install toolchain packages: winget not found"
}

# pwsh is deliberately installed first so later PowerShell DSC adapters and
# PowerShell 7 scripts can use it. Refresh PATH immediately after installation.
if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
    Write-Host "Installing PowerShell 7 (required by DSC's PowerShell adapter)..."
    Install-WingetPackage -Id "Microsoft.PowerShell"
    Update-ProcessPath
    if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        throw "PowerShell 7 package is installed but pwsh is still not on PATH. Refresh PATH or repair the Microsoft.PowerShell installation."
    }
}

# These are ordered explicitly and run only if their command is unavailable.
foreach ($tool in @(
    @{ Command = "curl.exe"; Id = "cURL.cURL" },
    @{ Command = "git.exe"; Id = "Git.Git" }
)) {
    if (-not (Get-Command $tool.Command -ErrorAction SilentlyContinue)) {
        Write-Host "Installing $($tool.Command) ($($tool.Id))..."
        Install-WingetPackage -Id $tool.Id
        Update-ProcessPath
        if (-not (Get-Command $tool.Command -ErrorAction SilentlyContinue)) {
            throw "$($tool.Id) is reported installed but $($tool.Command) is still not on PATH after refresh. Check the package install scope and PATH entries."
        }
    }
}

# PowerShell DSC v3 (dsc CLI)
if (-not (Get-Command dsc -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "cannot install DSC v3: winget not found"
    }

    Write-Host "Installing PowerShell DSC v3 (DesiredStateConfiguration, msstore)..."
    Install-WingetPackage -Id "9NVTPZWRC6KQ" -Source "msstore"
    Update-ProcessPath
    if (-not (Get-Command dsc -ErrorAction SilentlyContinue)) {
        throw "DesiredStateConfiguration package is installed but dsc is still not on PATH. Refresh PATH or repair the Store package."
    }
}

# Refresh PATH in case DSC or its Store package was just installed.
Update-ProcessPath

Set-Location $SourceDir

if ($env:DOTFILES_TEST -eq '1') {
    # Test lane applies over SSH, winget resolves some exe installers via
    # ShellExecuteEx('runas'), which may fail there. Skip BuildTools explicitly.
    Write-Host 'Test lane: skipping VS BuildTools package and workload setup'
    exit 0
}

# Install BuildTools when vswhere cannot find an existing instance.
# WinGet's native DSC package resource may try to launch the Visual Studio
# bootstrapper, even when the VS instance is already installed.
$VsConfig = Join-Path $SourceDir "Documents/dot_buildtools.vsconfig"
$installerDir = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
$vswhere = Join-Path $installerDir "vswhere.exe"
$setupExe = Join-Path $installerDir "setup.exe"

if (-not (Test-Path $VsConfig)) {
    throw "Could not find BuildTools workload config at '$VsConfig'."
}

$buildToolsInstance = $null
if (Test-Path $vswhere) {
    $buildToolsInstance = & $vswhere `
        -products Microsoft.VisualStudio.Product.BuildTools `
        -latest `
        -format json 2>$null | ConvertFrom-Json
}

if (-not $buildToolsInstance -or [string]::IsNullOrWhiteSpace($buildToolsInstance.installationPath)) {
    Write-Host 'Installing Microsoft Visual Studio Build Tools...'
    Install-WingetPackage -Id 'Microsoft.VisualStudio.BuildTools'
    Update-ProcessPath
}

if (-not (Test-Path $vswhere)) {
    throw "Could not find vswhere.exe at '$vswhere'."
}
if (-not (Test-Path $setupExe)) {
    throw "Could not find setup.exe at '$setupExe'."
}

$buildToolsInstance = & $vswhere `
    -products Microsoft.VisualStudio.Product.BuildTools `
    -latest `
    -format json 2>$null | ConvertFrom-Json
$installationPath = $buildToolsInstance.installationPath

if (-not $buildToolsInstance -or [string]::IsNullOrWhiteSpace($installationPath)) {
    throw "Could not locate a Visual Studio Build Tools installation."
}

Write-Host "Configuring Visual Studio Build Tools at '$installationPath'..."
$arguments = @(
    'modify'
    "--installPath `"$installationPath`""
    "--config `"$VsConfig`""
    '--passive'
    '--norestart'
) -join ' '

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $process = Start-Process `
        -FilePath $setupExe `
        -ArgumentList $arguments `
        -Wait `
        -PassThru
} else {
    $process = Start-Process `
        -FilePath $setupExe `
        -ArgumentList $arguments `
        -Verb RunAs `
        -Wait `
        -PassThru
}

if ($process.ExitCode -ne 0) {
    throw "Visual Studio configuration failed with exit code $($process.ExitCode)."
}
