$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# The bake waits for two files: C:\provision-done on success and
# C:\provision-failed.txt with the error on failure. The transcript makes a
# failed unattended run diagnosable after the fact.
Start-Transcript -Path 'C:\provision.log' -Force | Out-Null

$HarnessPublicKey = '@@HARNESS_PUBLIC_KEY@@'
$AuthorizedKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$SshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
$SshdDefault = Join-Path $env:WINDIR 'System32\OpenSSH\sshd_config_default'
$ProbeFailed = $false

# First-logon winget/Store operations are occasionally transient (Store not yet
# ready: "Requires store access", or "another installation is in progress").
# Retry a few times instead of failing the whole bake.
function Invoke-Winget {
    param([string[]]$Arguments, [int]$Attempts = 5, [int]$DelaySeconds = 20)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        & winget.exe @Arguments
        if ($LASTEXITCODE -eq 0) { return }
        Write-Host "winget $($Arguments -join ' ') failed (exit $LASTEXITCODE), attempt $attempt/$Attempts"
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "winget $($Arguments -join ' ') failed after $Attempts attempts (exit $LASTEXITCODE)"
}

try {
    foreach ($Capability in @(
        'OpenSSH.Client~~~~0.0.1.0',
        'OpenSSH.Server~~~~0.0.1.0'
    )) {
        $State = Get-WindowsCapability -Online -Name $Capability
        if ($State.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name $Capability | Out-Null
        }
    }

    # The capability may install this rule scoped to the Private profile, while
    # QEMU's user-mode network is classified Public -- inbound SSH is then
    # dropped (local self-connections bypass the profile check, which is why
    # sshd can look healthy while the host cannot connect). Force all profiles.
    $FirewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $FirewallRule) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
            -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound `
            -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
    } else {
        Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any -Action Allow -ErrorAction Stop
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $AuthorizedKeys) -Force | Out-Null
    [System.IO.File]::WriteAllText($AuthorizedKeys, "$HarnessPublicKey`r`n", [System.Text.Encoding]::ASCII)
    & icacls.exe $AuthorizedKeys /inheritance:r | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to disable inherited authorized_keys ACLs' }
    & icacls.exe $AuthorizedKeys /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set administrators_authorized_keys ACLs' }

    # The capability installs the binaries but not always a config under
    # ProgramData; sshd will not start without one. The shipped default already
    # contains the active `Match Group administrators` block pointing at
    # administrators_authorized_keys, so seed it verbatim.
    if (-not (Test-Path $SshdConfig)) {
        Copy-Item -Path $SshdDefault -Destination $SshdConfig -Force
    }

    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service sshd).Status -eq 'Running') {
        Restart-Service sshd -Force
    } else {
        Start-Service sshd
    }
    $FirewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $FirewallRule -or $FirewallRule.Enabled -ne 'True' -or $FirewallRule.Action -ne 'Allow') {
        throw 'OpenSSH firewall rule is missing, disabled, or blocking'
    }

    # `winget configure --enable` was provisioned for the old winget.dsc.yaml
    # wrapper; Phase 2 (plans/dsc) switched run_onchange_after_25-dsc-configure
    # to direct `dsc config set` on ~/.config/dsc/packages.dsc.yaml, which does
    # not require the flag — kept for Phase-3 adapted-PSDSC fallback pending
    # confirmation it can be dropped at the next golden bake (VALIDATION.md).
    Invoke-Winget -Arguments @('configure', '--enable')

    # Mirror the production prerequisite hook: install Microsoft DSC from the
    # Store package (DesiredStateConfiguration), not the winget Microsoft.DSC
    # package.
    if (-not (Get-Command dsc.exe -ErrorAction SilentlyContinue)) {
        Invoke-Winget -Arguments @('install', '--id', '9NVTPZWRC6KQ', '--source', 'msstore',
            '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity')
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + $env:Path
    }

    if (-not (Test-Path 'C:\Program Files\Python312\python.exe')) {
        Invoke-Winget -Arguments @('install', '--id', 'Python.Python.3.12', '--exact', '--scope', 'machine',
            '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity')
    }

    # The read-source-state hook is a .ps1 run through the `pwsh` interpreter
    # (chezmoi `interpreters.ps1`), so PowerShell 7 must exist in the golden.
    # winget's Microsoft.PowerShell package fails here with 0x80070002, so use
    # the official zip release (pinned; no Store involvement).
    $PwshVersion = '7.6.8'
    $PwshDir = 'C:\Program Files\PowerShell\7'
    if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $PwshZip = Join-Path $env:TEMP "PowerShell-$PwshVersion-win-x64.zip"
        Invoke-WebRequest -UseBasicParsing `
            -Uri "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/PowerShell-$PwshVersion-win-x64.zip" `
            -OutFile $PwshZip
        Expand-Archive -Path $PwshZip -DestinationPath $PwshDir -Force
        Remove-Item -Path $PwshZip -Force
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($machinePath -notlike "*$PwshDir*") {
            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$PwshDir", 'Machine')
        }
        $env:Path = "$PwshDir;$env:Path"
    }

    # Because the launcher uses -ExecutionPolicy Bypass (Process scope),
    # PowerShell reports ExecutionPolicyOverride after updating LocalMachine.
    # That is benign; pwsh/chezmoi use -ExecutionPolicy Bypass anyway.
    try {
        Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -ErrorAction Stop
    } catch {
        Write-Warning "Could not set LocalMachine execution policy: $($_.Exception.Message)"
    }

    # Keep the golden stable across test runs. This affects only Windows Update's
    # download/install services; normal servicing can be restored by the user.
    # UsoSvc is protected on some builds, so this is best-effort.
    foreach ($ServiceName in @('wuauserv', 'UsoSvc')) {
        try {
            $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if (-not $Service) { continue }
            if ($Service.Status -ne 'Stopped') {
                Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
        } catch {
            Write-Warning "Could not disable ${ServiceName}: $($_.Exception.Message)"
        }
    }

    Remove-Item -Path 'C:\provision-failed.txt' -Force -ErrorAction SilentlyContinue
    New-Item -ItemType File -Path 'C:\provision-done' -Force | Out-Null
}
catch {
    $ProbeFailed = $true
    ($_ | Out-String) | Set-Content -Path 'C:\provision-failed.txt' -Encoding UTF8
}
finally {
    Stop-Transcript | Out-Null
}

if ($ProbeFailed) {
    # Power off so the harness sees the failure immediately instead of waiting
    # out its SSH timeout. The disk (with provision-failed.txt/provision.log)
    # is kept for inspection.
    Stop-Computer -Force
    exit 1
}
