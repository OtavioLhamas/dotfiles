#!/usr/bin/env bash
# stage_windows.sh — doctor, dry-run, apply, and verify for the Windows lane.

stage_lint_windows_unattend() {
    python3 "$DOTFILES_TEST_RUNNER_DIR/test_windows_unattend.py"
}

windows_preseed_text() {
    preseed_config_text '@@WINDOWS_SOURCE_DIR@@' "$1"
}

windows_write_preseed() {
    local record="$1" port="$2" config encoded script
    config="$(windows_preseed_text "$record")"
    encoded="$(printf '%s' "$config" | base64 -w0)"
    script="$(cat <<'PS'
$repo = Join-Path $env:USERPROFILE '.local\share\chezmoi'
$source = (Join-Path $repo 'chezmoi').Replace('\','/')
$yaml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@CONFIG@@'))
$yaml = $yaml.Replace('@@WINDOWS_SOURCE_DIR@@', $source)
$cfg = Join-Path $env:USERPROFILE '.config\chezmoi\chezmoi.yaml'
New-Item -ItemType Directory -Path (Split-Path -Parent $cfg) -Force | Out-Null
[IO.File]::WriteAllText($cfg, $yaml, [Text.UTF8Encoding]::new($false))
PS
)"
    script="${script//@@CONFIG@@/$encoded}"
    windows_ssh_ps "$port" "$script"
}

windows_doctor_script() {
    cat <<'PS'
$ErrorActionPreference = 'Continue'
$failed = $false
$chezmoi = Join-Path $env:USERPROFILE '.local\bin\chezmoi.exe'
if (Test-Path $chezmoi) {
    & $chezmoi doctor
    if ($LASTEXITCODE -ne 0) { $failed = $true }
} elseif (Get-Command chezmoi -ErrorAction SilentlyContinue) {
    chezmoi doctor
    if ($LASTEXITCODE -ne 0) { $failed = $true }
} else {
    Write-Output 'chezmoi: not installed yet'
}
winget.exe --info
if ($LASTEXITCODE -ne 0) { $failed = $true }
dsc.exe --version
if ($LASTEXITCODE -ne 0) { $failed = $true }
dsc.exe resource list --output-format json
if ($LASTEXITCODE -ne 0) { $failed = $true }
$sshd = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
if (-not $sshd -or $sshd.State -ne 'Running' -or $sshd.StartMode -ne 'Auto') {
    Write-Error 'sshd is not running with Automatic startup'
    $failed = $true
} else {
    Write-Output 'sshd: running (Automatic)'
}
if ($failed) { exit 1 }
PS
}

stage_windows_doctor() {
    windows_ssh_ps "$2" "$(windows_doctor_script)"
}

windows_dsc_test_script() {
    local require_desired="${1:-0}" script
    script="$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$requireDesired = @@REQUIRE_DESIRED@@
$repo = Join-Path $env:USERPROFILE '.local\share\chezmoi'
# DSC documents live at their DEPLOYED location (~/.config/dsc) since the
# phase-2 refactor moved them to chezmoi templates (dot_config/dsc/*.tmpl);
# the old .chezmoidata glob no longer matches anything (2026-11-13).
$deployed = Join-Path $env:USERPROFILE '.config\dsc'
$files = @(Get-ChildItem -Path $deployed -Filter '*.dsc.yaml' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($files.Count -eq 0) {
    if ($requireDesired) { throw 'No DSC v3 configuration documents were found' }
    Write-Output 'No DSC v3 configuration documents are present yet.'
    exit 0
}
$failed = $false
foreach ($file in $files) {
    Write-Output "--- dsc config test: $($file.Name) ---"
    $output = & dsc.exe config test --file $file.FullName 2>&1
    $rc = $LASTEXITCODE
    $output | ForEach-Object { Write-Output $_ }
    if ($rc -ne 0 -and ($requireDesired -or ($output -join "`n") -notmatch '(?i)"?inDesiredState"?\s*:\s*false')) {
        $failed = $true
        continue
    }
    if ($requireDesired -and ($output -join "`n") -notmatch '(?i)"?inDesiredState"?\s*:\s*true') {
        Write-Error "$($file.Name) is not in desired state"
        $failed = $true
    }
}
if ($failed) { exit 1 }
PS
)"
    if [ "$require_desired" = "1" ]; then
        script="${script//@@REQUIRE_DESIRED@@/\$true}"
    else
        script="${script//@@REQUIRE_DESIRED@@/\$false}"
    fi
    printf '%s' "$script"
}

windows_run_dsc_tests() {
    windows_ssh_ps "$1" "$(windows_dsc_test_script "${2:-0}")"
}

stage_windows_dry_run() {
    local record="$1" port="$2" script
    windows_write_preseed "$record" "$port" || return 1
    script="$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$repo = Join-Path $env:USERPROFILE '.local\share\chezmoi'
$source = Join-Path $repo 'chezmoi'
$bin = Join-Path $env:USERPROFILE '.local\bin'
$chezmoi = Join-Path $bin 'chezmoi.exe'
if (-not (Test-Path $chezmoi)) {
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    iex "&{$(irm 'https://get.chezmoi.io/ps1')} -b '$bin'"
}
# Match the apply stage's hook behavior: `chezmoi init` always executes the
# pre-requisites hook for real (hooks are not dry-run-able), and without
# DOTFILES_TEST it installed BuildTools + workloads here (~10 GB + 40 min per
# run, twice the toolchain, and the apply then hit disk-full: the 2026-11-13
# Vivaldi/Bitwarden cascade). Test-lane-only env, not production.
$env:DOTFILES_TEST = '1'
$env:DOTFILES_TEST_SKIP_WSL = '1'
# Grow C: into the unallocated tail created by the overlay resize. The baked
# layout ends with a RECOVERY partition (GPT type de94bba4-...) that blocks
# Resize-Partition (SizeMax stays ~63G on a 96G disk — run 9, 2026-11-13);
# remove it first (lab VM — no recovery partition needed), then extend.
# Idempotent: no-ops when C: already ends at the disk tail.
$recoveries = Get-Partition -DiskNumber 0 | Where-Object { $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' }
foreach ($r in $recoveries) { $r | Remove-Partition -Confirm:$false }
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
$cur = (Get-Partition -DriveLetter C).Size
if ($max -gt $cur) {
    Resize-Partition -DriveLetter C -Size $max
    Write-Output "C: extended to $([math]::Round($max/1GB)) GB"
}
$env:PATH = "$bin;$env:PATH"
Set-Location $env:USERPROFILE
& $chezmoi init --source $source
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $chezmoi apply --dry-run --verbose --source $source
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Output 'chezmoi dry-run completed.'
PS
)"
    windows_ssh_ps "$port" "$script" || return 1
    # A clean golden is expected to report drift here; this is the preview.
    windows_run_dsc_tests "$port" 0
}

stage_windows_apply() {
    local record="$1" port="$2" script rc=0
    windows_write_preseed "$record" "$port" || return 1
    script="$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$repo = Join-Path $env:USERPROFILE '.local\share\chezmoi'
$env:DOTFILES_TEST = '1'
$env:DOTFILES_TEST_SKIP_WSL = '1'
# The guest's NAT can be slow for long GitHub downloads; mise's default 30s
# HTTP timeout fails whole tool installs. Test-lane-only env, not production.
$env:MISE_HTTP_TIMEOUT = '600'
# Grow C: into any unallocated tail created by the overlay resize (the baked
# golden partition is smaller than the declared matrix disk; idempotent no-op
# when already maxed). Without this the apply hit disk-full mid-install
# (2026-11-13 Vivaldi/Bitwarden cascade).
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
$cur = (Get-Partition -DriveLetter C).Size
if ($max -gt $cur) {
    Resize-Partition -DriveLetter C -Size $max
    Write-Output "C: extended to $([math]::Round($max/1GB)) GB"
}
$env:PATH = (Join-Path $env:USERPROFILE '.local\bin') + ';' + $env:PATH
Set-Location $repo
& (Join-Path $repo 'bootstrap.ps1')
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
PS
)"
    windows_ssh_ps "$port" "$script" || rc=$?
    stage_windows_collect_artifacts "$record" "$port" || true
    return "$rc"
}

windows_chezmoi_diff_script() {
    cat <<'PS'
$ErrorActionPreference = 'Stop'
$repo = Join-Path $env:USERPROFILE '.local\share\chezmoi'
$source = Join-Path $repo 'chezmoi'
$chezmoi = Join-Path $env:USERPROFILE '.local\bin\chezmoi.exe'
$diff = (& $chezmoi diff --source $source 2>&1 | Out-String)
$headers = [regex]::Matches($diff, '(?m)^diff --git a/(.*?) b/.*$') | ForEach-Object { $_.Groups[1].Value }
$remaining = @($headers | Where-Object { $_ -and $_ -notmatch '^\.chezmoiscripts/' -and $_ -ne '.chezmoiversion' })
if ($remaining.Count -gt 0) {
    Write-Output 'chezmoi diff is not empty:'
    $remaining | ForEach-Object { Write-Output "  $_" }
    exit 1
}
Write-Output 'chezmoi diff: clean (script-entry noise ignored)'
PS
}

stage_windows_verify() {
    local record="$1" port="$2"
    stage_windows_collect_artifacts "$record" "$port" || true
    windows_ssh_ps "$port" "$(windows_chezmoi_diff_script)" || return 1
    windows_run_dsc_tests "$port" 1 || return 1
    stage_windows_doctor "$record" "$port" || return 1
    stage_windows_ansible_probe "$record" "$port"
}

stage_windows_collect_artifacts() {
    local record="$1" port="$2" name rdir
    name="$(record_get "$record" '.name')"
    rdir="$(log_result_dir "$name")"
    mkdir -p "$rdir"
    windows_ssh_ps "$port" 'dsc.exe resource list --output-format json' \
        >"$rdir/dsc-resource-list.json" 2>&1 || true
    windows_ssh_ps "$port" 'winget.exe list' >"$rdir/winget-list.txt" 2>&1 || true
    windows_ssh_ps "$port" "$(windows_dsc_test_script 0)" \
        >"$rdir/dsc-config-test.txt" 2>&1 || true
    windows_ssh_ps "$port" "\$repo=Join-Path \$env:USERPROFILE '.local\\share\\chezmoi'; \$chezmoi=Join-Path \$env:USERPROFILE '.local\\bin\\chezmoi.exe'; & \$chezmoi state dump --format json --source (Join-Path \$repo 'chezmoi')" \
        >"$rdir/chezmoi-state.json" 2>/dev/null || rm -f "$rdir/chezmoi-state.json"
    return 0
}

stage_windows_ansible_probe() {
    local record="$1" port="$2" rdir inventory probe become_file
    rdir="$(log_result_dir "$(record_get "$record" '.name')")"
    inventory="$rdir/winvm-test.yaml"
    probe="$rdir/winvm-probe.yaml"
    become_file="${DOTFILES_TEST_BECOME_FILE:-}"
    [ -f "$become_file" ] || { log_error "DOTFILES_TEST_BECOME_FILE is required for the Windows runas probe"; return 1; }
    command -v ansible-playbook >/dev/null 2>&1 || { log_error "ansible-playbook is required for the Windows lane probe"; return 1; }
    [ -f "$DOTFILES_TEST_REPO_ROOT/ansible/winvm.yaml" ] || { log_error "ansible/winvm.yaml is required for the Windows lane probe"; return 1; }
    local mode
    mode="$(stat -c '%a' "$become_file")"
    if (( (8#$mode & 077) != 0 )); then
        log_error "DOTFILES_TEST_BECOME_FILE must not be readable by group/other"
        return 1
    fi
    WINDOWS_ANSIBLE_PYTHON='C:\Program Files\Python312\python.exe' \
    WINDOWS_SSH_KEY_FILE="$(ssh_key)" \
    WINDOWS_ANSIBLE_PORT="$port" \
        yq '
          .ungrouped.hosts.windows_11.ansible_host = "127.0.0.1"
          | .ungrouped.hosts.windows_11.ansible_port = strenv(WINDOWS_ANSIBLE_PORT)
          | .ungrouped.hosts.windows_11.ansible_user = "provision"
          | .ungrouped.hosts.windows_11.ansible_connection = "ssh"
          | .ungrouped.hosts.windows_11.ansible_shell_type = "cmd"
          | .ungrouped.hosts.windows_11.ansible_python_interpreter = strenv(WINDOWS_ANSIBLE_PYTHON)
          | .ungrouped.hosts.windows_11.ansible_ssh_private_key_file = strenv(WINDOWS_SSH_KEY_FILE)
          | .ungrouped.hosts.windows_11.ansible_ssh_common_args = "-o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        ' "$DOTFILES_TEST_REPO_ROOT/ansible/winvm.yaml" >"$inventory"
    printf '%s\n' \
        '---' \
        '- name: Verify Windows SSH and elevated Ansible execution' \
        '  hosts: windows_11' \
        '  gather_facts: false' \
        '  tasks:' \
        '    - name: Verify the target Python interpreter' \
        '      ansible.builtin.ping:' \
        '    - name: Verify runas elevation' \
        '      ansible.builtin.raw: net session' \
        '      become: true' \
        '      become_method: runas' \
        '      become_user: provision' \
        >"$probe"
    ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$inventory" "$probe" \
        --become-password-file "$become_file"
}
