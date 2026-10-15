# Dotfiles bootstrap script for Windows 11 Native
# Minimal bootstrap: installs chezmoi, then runs `chezmoi init --apply`.
# Everything else is intentionally NOT supported here: use -SkipInit to
# install chezmoi only, then run any `chezmoi` command yourself.
#
# Usage:
#   bootstrap.ps1 [-SkipInit] [-BinDir DIR] [-Source DIR|URL] [-Help]
#
# Options (flag wins over env; names are case-insensitive, - or -- prefix):
#   -SkipInit        Install chezmoi but do not run `chezmoi init`
#   -BinDir DIR      Install chezmoi to DIR (env: DOTFILES_BINDIR,
#                    default: $HOME/.local/bin)
#   -Source DIR|URL  Local source dir or remote repo URL (env: DOTFILES_SOURCE,
#                    default: <script_dir>\chezmoi when run from a checkout,
#                    else DOTFILES_REPO_URL or the default remote below)
#   -Help            Show this help and exit
#
# Any other argument is ignored with a warning. Arguments are parsed
# manually (no param block) so single-dash values like -S are never mistaken
# for this script's own parameters.

$ErrorActionPreference = "Stop"

$DefaultRepoUrl = "https://github.com/OtavioLhamas/dotfiles.git"

function Show-Usage {
    @'
Usage: bootstrap.ps1 [-SkipInit] [-BinDir DIR] [-Source DIR|URL] [-Help]

  -SkipInit        Install chezmoi but do not run `chezmoi init`
  -BinDir DIR      Install chezmoi to DIR (env: DOTFILES_BINDIR)
  -Source DIR|URL  Local source dir or remote repo (env: DOTFILES_SOURCE)
  -Help            Show this help and exit

Any other argument is ignored. To customize the init command, use
-SkipInit and run `chezmoi init` yourself.
'@
}

$SkipInit = $false
$BinDir = if ($env:DOTFILES_BINDIR) { $env:DOTFILES_BINDIR } else { "$HOME/.local/bin" }
$SourceArg = if ($env:DOTFILES_SOURCE) { $env:DOTFILES_SOURCE } else { "" }
$ignored = @()
$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    switch -regex ($a) {
        '^(-{1,2})(skip-init|Help|h|help)$' {
            if ($Matches[2] -ieq 'skip-init') { $SkipInit = $true } else { Show-Usage; exit 0 }
            $i += 1
        }
        '^(-{1,2})bin-dir=(.+)$' { $BinDir = $Matches[2]; $i += 1 }
        '^(-{1,2})bin-dir$' { $BinDir = $args[$i + 1]; $i += 2 }
        '^(-{1,2})source=(.+)$' { $SourceArg = $Matches[2]; $i += 1 }
        '^(-{1,2})source$' { $SourceArg = $args[$i + 1]; $i += 2 }
        '^--$' { $i += 1 }
        default { $ignored += $a; $i += 1 }
    }
}
foreach ($u in $ignored) {
    Write-Warning "Ignoring unknown argument: $u"
}

# --- install chezmoi (latest from get.chezmoi.io, no version pin) ---
$chezmoi_cmd = $null
if (($found = Get-Command chezmoi -ErrorAction SilentlyContinue)) {
    $chezmoi_cmd = $found.Source
    Write-Host "chezmoi already installed: $chezmoi_cmd"
} elseif (Test-Path "$BinDir/chezmoi.exe" -PathType Leaf) {
    $chezmoi_cmd = "$BinDir/chezmoi.exe"
    Write-Host "chezmoi already installed: $chezmoi_cmd"
} elseif (Test-Path "$BinDir/chezmoi" -PathType Leaf) {
    $chezmoi_cmd = "$BinDir/chezmoi"
    Write-Host "chezmoi already installed: $chezmoi_cmd"
} else {
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
    Write-Host "Installing chezmoi to '$BinDir'..."
    iex "&{$(irm 'https://get.chezmoi.io/ps1')} -b '$BinDir'"
    foreach ($candidate in @("$BinDir/chezmoi.exe", "$BinDir/chezmoi")) {
        if (Test-Path $candidate -PathType Leaf) {
            $chezmoi_cmd = $candidate
            break
        }
    }
    if (-not $chezmoi_cmd) {
        Write-Error "chezmoi installation failed (no executable under '$BinDir')"
        exit 1
    }
}

if ($SkipInit) {
    Write-Host "Skipping init (-SkipInit)."
    exit 0
}

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Host "Installing pwsh..."
    winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent
}

# --- resolve source: flag > env > local checkout > remote ---
if ([string]::IsNullOrEmpty($SourceArg)) {
    $script_dir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $source_path = Join-Path $script_dir "chezmoi"
    if (Test-Path $source_path -PathType Container) {
        $SourceArg = $source_path
    } elseif ($env:DOTFILES_REPO_URL) {
        $SourceArg = $env:DOTFILES_REPO_URL
    } else {
        $SourceArg = $DefaultRepoUrl
    }
}

# A URL is a repo positional; anything else is a local --source dir.
$finalArgs = @('init', '--apply')
if ($SourceArg -like '*://*') {
    $finalArgs += $SourceArg
} else {
    if (-not (Test-Path $SourceArg -PathType Container)) {
        Write-Error "Source '$SourceArg' is not a directory"
        exit 1
    }
    $finalArgs += "--source=$SourceArg"
}

Write-Host "Running 'chezmoi $($finalArgs -join ' ')'" -ForegroundColor Cyan
& $chezmoi_cmd @finalArgs
