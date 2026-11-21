#!/usr/bin/env bash
# preseed.sh — non-interactive mechanism: scenario chezmoi config, env prefix,
# and the become-password file.
#
# Sourced by test/run.sh. Requires yq v4.

# preseed_config_text <source-dir> <scenario-record-json>
# Prints the minimal chezmoi config for the scenario. `prompt*Once` calls read
# existing `data` and return without prompting; `sourceDir` points at the tree.
# Intentionally omits `hooks:` so the read-source-state prerequisite hook does
# not run during host lint (it is a target concern, not a render concern).
preseed_config_text() {
    local source_dir="$1" record="$2"
    printf 'sourceDir: "%s"\n' "$source_dir"
    printf 'data:\n'
    printf '  categories:\n'
    printf '%s' "$record" | yq -p=json -r '.data.categories[]' | while IFS= read -r c; do
        printf '    - "%s"\n' "$c"
    done
    printf '  form_factor: "%s"\n' "$(printf '%s' "$record" | yq -p=json -r '.data.form_factor')"
    printf '  desktop_environment: "%s"\n' "$(printf '%s' "$record" | yq -p=json -r '.data.desktop_environment')"
    printf '  display_server: "%s"\n' "$(printf '%s' "$record" | yq -p=json -r '.data.display_server')"
}

# preseed_write_config <dest> <scenario-record-json>  (host path)
preseed_write_config() {
    local dest="$1" record="$2"
    mkdir -p "$(dirname "$dest")"
    preseed_config_text "$DOTFILES_TEST_REPO_ROOT/chezmoi" "$record" >"$dest"
}

# preseed_env_for_record <scenario-record-json>
# Prints `export KEY=VALUE` lines for the scenario env (init-time DE/DS knobs).
preseed_env_for_record() {
    local record="$1" key val
    while IFS=$'\t' read -r key val; do
        [ -n "$key" ] || continue
        printf 'export %s=%q\n' "$key" "$val"
    done < <(printf '%s' "$record" | yq -p=json -r '.env | to_entries[] | [.key, .value] | @tsv')
}

# preseed_become_file <dir> — create an empty (NOPASSWD) become-password file,
# chmod 600, and print its path.
preseed_become_file() {
    local dir="$1"
    mkdir -p "$dir"
    local f="$dir/become-password"
    : >"$f"
    chmod 600 "$f"
    printf '%s' "$f"
}
