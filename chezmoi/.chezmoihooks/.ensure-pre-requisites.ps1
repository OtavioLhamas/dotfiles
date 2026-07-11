# Runs during hooks.read-source-state.pre (NOT a template)

$ErrorActionPreference = "Stop"

# Determine source directory for reading declarative files
$SourceDir = if ($env:CHEZMOI_SOURCE_DIR) { $env:CHEZMOI_SOURCE_DIR } else { Split-Path -Parent $PSScriptRoot }
$VsConfig = Join-Path $SourceDir "Documents/dot_buildtools.vsconfig"

$packages = @{
    curl = "cURL.cURL"
    git  = "Git.Git"
    bw   = "Bitwarden.CLI"
}

$missing = @()
foreach ($cmd in $packages.Keys) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        $missing += $cmd
    }
}

if ($missing.Count -gt 0) {
    Write-Host "Installing missing packages: $($missing -join ', ')"
    foreach ($cmd in $missing) {
        $id = $packages[$cmd]
        Write-Host "Installing $id via winget..."
        winget install --id $id --accept-source-agreements --accept-package-agreements --silent
    }

    Write-Host "Refresh your shell to apply PATH changes"
}

$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$machinePath;$userPath"

# --- VS BuildTools install + workload configuration ---
$installerDir = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
$vswhere  = Join-Path $installerDir "vswhere.exe"
$setupExe = Join-Path $installerDir "setup.exe"

$btInstalled = $false
if (Test-Path $vswhere) {
    $instance = & $vswhere `
        -products Microsoft.VisualStudio.Product.BuildTools `
        -latest `
        -format json 2>$null | ConvertFrom-Json
    $btInstalled = ($null -ne $instance.installationPath)
}

if (-not $btInstalled) {
    Write-Host "Installing Microsoft.VisualStudio.BuildTools via winget..."
    winget install --id Microsoft.VisualStudio.BuildTools --accept-source-agreements --accept-package-agreements --silent
}

if (-not (Test-Path $vswhere)) {
    throw "Could not find vswhere.exe at '$vswhere'."
}

if (-not (Test-Path $setupExe)) {
    throw "Could not find setup.exe at '$setupExe'."
}

$instance = & $vswhere `
    -products Microsoft.VisualStudio.Product.BuildTools `
    -latest `
    -format json | ConvertFrom-Json

$installationPath = $instance.installationPath

if (-not $instance -or [string]::IsNullOrWhiteSpace($installationPath)) {
    throw "Could not locate a Visual Studio Build Tools installation."
}

if (Test-Path $VsConfig) {
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
    }
    else {
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
}

# --- Bitwarden login ---
if (Get-Command bw -ErrorAction SilentlyContinue) {
    try {
        # If running bw for the first time, Windows says it did not
        # find the folder and has to create it, then it will error out
        $bwRawStatus = bw status 2>$null
    } catch {
        Write-Host "Continue..."
    }

    if ($null -ne $bwRawStatus) {
        $bwObj = $bwRawStatus | ConvertFrom-Json
        $bwStatus = if ($bwObj.status) { $bwObj.status } else { "unauthenticated" }

        # if ($bwStatus -eq "unauthenticated") {
        #     bw login
        # }
    }
}
