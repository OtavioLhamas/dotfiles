# Microsoft.PowerShell_profile.ps1 — managed by chezmoi

function __source {
    param([string]$cmd)
    $exe = $cmd.Split()[0]
    if (Get-Command $exe -ErrorAction SilentlyContinue) {
        $sb = [scriptblock]::Create($cmd)
         (& $sb) | Out-String | Invoke-Expression
    }
}

if ($env:PATH -split [IO.Path]::PathSeparator -notcontains "$HOME\.opencode\bin") {
    $env:PATH = "$HOME\.opencode\bin$([IO.Path]::PathSeparator)$env:PATH"
}
if ($env:PATH -split [IO.Path]::PathSeparator -notcontains "$HOME\.local\bin") {
    $env:PATH = "$HOME\.local\bin$([IO.Path]::PathSeparator)$env:PATH"
}

__source "mise activate pwsh"
__source "zoxide init powershell"
__source "starship init powershell"
__source "atuin init powershell"
Remove-Item Function:\__source -ErrorAction SilentlyContinue
