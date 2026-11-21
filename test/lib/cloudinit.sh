#!/usr/bin/env bash
# cloudinit.sh — NoCloud seed rendering + seed ISO packing (VM lane, Phase C).
#
# cloud-init's NoCloud datasource reads `user-data` + `meta-data` from any
# filesystem labelled `cidata`; a genisoimage-built ISO is the transport. The
# unique instance-id per run is what makes cloud-init re-run on a fresh
# overlay while the golden stays untouched.
#
# Templates live in test/seed/*.yaml.tmpl and use the same @@TOKEN@@
# substitution as the remote stage scripts (render_script in stage_target.sh).
#
# Sourced by test/run.sh.

seed_template() { printf '%s/seed/%s' "$DOTFILES_TEST_RUNNER_DIR" "$1"; }

# cloudinit_instance_id <seed-key> — unique per harness run (and per seed).
cloudinit_instance_id() {
    printf 'dotfiles-%s-%s' "${LOG_RUN_ID:-adhoc-$(date +%s)}" "$1" | tr '.' '-'
}

# cloudinit_hostname <seed-key> — RFC1123-safe local-hostname.
cloudinit_hostname() { printf 'dotfiles-%s' "$1" | tr '.' '-'; }

# cloudinit_build_iso <iso-path> <seed-dir> — pack user-data + meta-data with
# the NoCloud `cidata` volume label (the label is the datasource contract).
cloudinit_build_iso() {
    local out="$1" dir="$2" tool
    out="$(cd "$(dirname "$out")" && pwd -P)/$(basename "$out")"
    for tool in genisoimage mkisofs; do
        if command -v "$tool" >/dev/null 2>&1; then
            (cd "$dir" && "$tool" -quiet -output "$out" -volid cidata -joliet -rock user-data meta-data) || return 1
            break
        fi
        tool=""
    done
    if [ -z "$tool" ]; then
        if command -v xorriso >/dev/null 2>&1; then
            (cd "$dir" && xorriso -as mkisofs -quiet -output "$out" -volid cidata -joliet -rock user-data meta-data) || return 1
        else
            log_error "no ISO tool (genisoimage/mkisofs/xorriso); run doctor-host"
            return 1
        fi
    fi
    # Cheap contract check when the inspector is available.
    if command -v isoinfo >/dev/null 2>&1; then
        if ! isoinfo -d -i "$out" 2>/dev/null | grep -qi 'Volume id: *cidata'; then
            log_error "seed ISO volume id is not cidata: $out"
            return 1
        fi
    fi
    return 0
}

# cloudinit_seed_iso <workdir> <template-name> KEY=VALUE... — render user-data
# + meta-data into <workdir>/seed/ and pack <workdir>/seed.iso. Side effects
# only; the ISO path is always <workdir>/seed.iso.
cloudinit_seed_iso() {
    local workdir="$1" template="$2"
    shift 2
    local key sdir="$workdir/seed" iid
    mkdir -p "$sdir"
    iid="$(cloudinit_instance_id "$(basename "$workdir")")"
    render_script "$(cat "$(seed_template "$template")")" "$@" >"$sdir/user-data" || return 1
    render_script "$(cat "$(seed_template meta-data.yaml.tmpl)")" \
        "INSTANCE_ID=$iid" \
        "LOCAL_HOSTNAME=$(cloudinit_hostname "$(basename "$workdir")")" >"$sdir/meta-data" || return 1
    # Validate the rendered YAML before booting: a malformed seed otherwise
    # costs a full bake timeout to discover (cloud-init ignores bad user-data).
    if command -v yq >/dev/null 2>&1; then
        yq -e '.' "$sdir/user-data" >/dev/null 2>&1 || {
            log_error "rendered user-data is not valid YAML: $sdir/user-data"
            return 1
        }
        yq -e '.' "$sdir/meta-data" >/dev/null 2>&1 || {
            log_error "rendered meta-data is not valid YAML: $sdir/meta-data"
            return 1
        }
    fi
    cloudinit_build_iso "$workdir/seed.iso" "$sdir"
}
