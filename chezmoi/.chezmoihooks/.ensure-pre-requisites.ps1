$ErrorActionPreference = "Stop"

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

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"

    Write-Host "Refresh your shell to apply PATH changes"
}

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
