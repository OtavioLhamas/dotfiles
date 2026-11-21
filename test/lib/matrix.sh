#!/usr/bin/env bash
# matrix.sh — load/validate test/matrix.yaml, resolve selectors, and
# synthesize ephemeral scenarios (the "variants as configs" mechanism).
#
# Sourced by test/run.sh. Requires yq v4 (mikefarah) and DOTFILES_TEST_REPO_ROOT.
#
# yq portability notes (kept compatible with minimal yq builds):
#   * object keys are always quoted;
#   * no `def`, no `if`/`then`/`else` (use `map(select(...)) | .[0]` and `//`);
#   * no `ascii_downcase` (use `test("(?i)...")`);
#   * `and`/`or` bind looser than `|`, so conditions are wrapped in parens.
# Filter/override inputs are passed as environment variables (no --arg support).

matrix_file() { printf '%s/test/matrix.yaml' "$DOTFILES_TEST_REPO_ROOT"; }

# --- classification ---------------------------------------------------------
#
# DE/DS are derived by rendering chezmoi/.chezmoi.yaml.tmpl with
# `execute-template --init` (which defines the init-only prompt*Once functions),
# so the config template is the single source of truth. A minimal hook-less
# config is passed via --config: using the real config would run the
# read-source-state hook (~3s and possible privilege escalation).

matrix_nohooks_config() {
    local dir="$DOTFILES_TEST_RUNNER_DIR/run"
    local cfg="$dir/chezmoi-nohooks.yaml"
    mkdir -p "$dir"
    printf 'sourceDir: "%s"\n' "$DOTFILES_TEST_REPO_ROOT/chezmoi" >"$cfg"
    printf '%s' "$cfg"
}

# classify_from_env <XDG_CURRENT_DESKTOP> <XDG_SESSION_TYPE>
# Prints {"de":"...","ds":"..."} as derived by .chezmoi.yaml.tmpl.
classify_from_env() {
    local xdg_desktop="${1:-}" xdg_session="${2:-}"
    local cfg
    cfg="$(matrix_nohooks_config)"
    XDG_CURRENT_DESKTOP="$xdg_desktop" XDG_SESSION_TYPE="$xdg_session" \
        chezmoi execute-template --init \
            --config "$cfg" \
            --source "$DOTFILES_TEST_REPO_ROOT/chezmoi" \
            <"$DOTFILES_TEST_REPO_ROOT/chezmoi/.chezmoi.yaml.tmpl" \
        | yq -o=json -I=0 '{"de": (.data.desktop_environment // "none"), "ds": (.data.display_server // "")}'
}

# matrix_classify_record — patch a record's data.desktop_environment /
# display_server from its env, leaving any explicit value in place.
matrix_classify_record() {
    local rec="$1"
    local env_de env_ds derived de ds
    env_de="$(printf '%s' "$rec" | yq -p=json -r '.env.XDG_CURRENT_DESKTOP // ""')"
    env_ds="$(printf '%s' "$rec" | yq -p=json -r '.env.XDG_SESSION_TYPE // ""')"
    derived="$(classify_from_env "$env_de" "$env_ds")"
    if [ -z "$derived" ]; then
        log_error "classification failed for env XDG_CURRENT_DESKTOP='$env_de' XDG_SESSION_TYPE='$env_ds'"
        derived='{"de":"none","ds":""}'
    fi
    de="$(printf '%s' "$derived" | yq -p=json -r '.de')"
    ds="$(printf '%s' "$derived" | yq -p=json -r '.ds')"
    printf '%s' "$rec" | DERIVED_DE="$de" DERIVED_DS="$ds" \
        yq -o=json -I=0 -p=json '
        .data.desktop_environment = (.data.desktop_environment // strenv(DERIVED_DE))
        | .data.display_server = (.data.display_server // strenv(DERIVED_DS))
    '
}

# --- validation -------------------------------------------------------------

matrix_validate() {
    local mf
    mf="$(matrix_file)"
    [ -f "$mf" ] || { log_error "matrix not found: $mf"; return 1; }

    # Clauses are collected in an array (not an `and` chain): yq's `and` has
    # order-sensitive parsing around `as` bindings, `[ f, g ] | all` is exact.
    yq -e '
      . as $root
      | [ (.version == 1),
          ([.scenarios | to_entries[] | .value.image as $i | ($root.images | has($i))] | all),
          ([.defaults.distros[] | .default_image as $d | ($root.images | has($d))] | all),
          ([.scenarios[] | (((.data.categories | type) == "!!seq") and ((.data.form_factor | type) == "!!str"))] | all),
          ([.scenarios[] | (((.expect.diff_allowlist // []) | type) == "!!seq")] | all),
          ([.images | to_entries[] | select(.value.type == "cloud")
            | (((((.value.url // "") | length) > 0)
               and (((((.value.sha256 // "") | length) > 0))
                    or (((.value.sha512 // "") | length) > 0))))] | all),
          ([.images | to_entries[] | select(.value.type == "cloud-baked")
            | (.value.base // "") as $b
            | ((($b | length) > 0)
              and ($root.images | has($b))
              and ((((.value.bake.packages // []) | type) == "!!seq")
                    and (((.value.bake.packages // []) | length) > 0)))] | all)
          , ([.images | to_entries[] | select(.value.type == "windows-baked")
             | ((.value.os == "windows") and (.value.lane == "windows")
                and (((.value.iso_env // "") | length) > 0))] | all)
        ] | all
    ' "$mf" >/dev/null || { log_error "matrix schema validation failed: $mf"; return 1; }

    local f
    shopt -s nullglob
    for f in "$DOTFILES_TEST_REPO_ROOT"/chezmoi/.chezmoidata/*.yaml; do
        yq -e '.' "$f" >/dev/null || { log_error "invalid chezmoidata: $f"; return 1; }
    done
    shopt -u nullglob
    return 0
}

matrix_names() {
    yq -r '.scenarios | keys | .[]' "$(matrix_file)"
}

# --- resolution -------------------------------------------------------------

# matrix_resolve_raw — resolve + filter scenarios (DE/DS not yet derived);
# print one compact JSON record per line.
matrix_resolve_raw() {
    local mf
    mf="$(matrix_file)"
    F_SCEN_CSV="${F_SCEN_CSV:-}" \
    F_IMG_CSV="${F_IMG_CSV:-}" \
    F_DISTRO_CSV="${F_DISTRO_CSV:-}" \
    F_OS_CSV="${F_OS_CSV:-}" \
    F_LANE_CSV="${F_LANE_CSV:-}" \
        yq -o=json -I=0 '
        . as $root
        | [ .scenarios | to_entries[]
            | .key as $name
            | .value as $s
            | ($root.images[$s.image]) as $img
            | ($s.env // {}) as $env
            | {
                "name": $name,
                "image": $s.image,
                "lane": ($s.lane // $img.lane),
                "os": $img.os,
                "distro": $img.distro,
                # NB: `//` treats false as empty, so an explicit `nix: false`
                # must be honored via has() rather than `$s.nix // default`.
                "nix": ([{"m": ($s | has("nix")), "v": $s.nix},
                         {"m": true, "v": $root.defaults.nix}]
                        | map(select(.m)) | .[0].v),
                "data": (($s.data // {})
                  | .categories = (.categories // [])
                  | .form_factor = (.form_factor // "desktop")
                ),
                "env": $env,
                "expect": ($s.expect // {})
              }
          ]
        | map(select(
            . as $rec
            | [
                (strenv(F_SCEN_CSV) == "" or ((strenv(F_SCEN_CSV) | split(",")) | contains([$rec.name]))),
                (strenv(F_IMG_CSV) == "" or ((strenv(F_IMG_CSV) | split(",")) | contains([$rec.image]))),
                (strenv(F_DISTRO_CSV) == "" or ((strenv(F_DISTRO_CSV) | split(",")) | contains([$rec.distro]))),
                (strenv(F_OS_CSV) == "" or ((strenv(F_OS_CSV) | split(",")) | contains([$rec.os]))),
                (strenv(F_LANE_CSV) == "" or ((strenv(F_LANE_CSV) | split(",")) | contains([$rec.lane])))
              ] | all
          ))
        | .[]
    ' "$mf"
}

# matrix_resolve — resolve scenarios and derive DE/DS from .chezmoi.yaml.tmpl.
matrix_resolve() {
    local rec
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        matrix_classify_record "$rec"
    done < <(matrix_resolve_raw)
}

# matrix_apply_overrides — read one scenario record (JSON) on stdin, apply the
# OV_* overrides, and print the updated record.
matrix_apply_overrides() {
    OV_FORM="${OV_FORM:-}" \
    OV_DE="${OV_DE:-}" \
    OV_DS="${OV_DS:-}" \
    OV_DS_SET="${OV_DS_SET:-0}" \
    OV_CATS="${OV_CATS:-}" \
        yq -o=json -I=0 -p=json '
        . as $r
        | (strenv(OV_FORM)) as $ov_form
        | (strenv(OV_DE)) as $ov_de
        | (strenv(OV_DS)) as $ov_ds
        | (strenv(OV_DS_SET)) as $ov_ds_set
        | ((strenv(OV_CATS)) | split(",") | map(select(. != ""))) as $ov_cats
        | .data.form_factor = (($ov_form | select(. != "")) // .data.form_factor)
        | .data.categories = (($ov_cats | select(length > 0)) // .data.categories)
        | .data.desktop_environment = (($ov_de | select(. != "")) // .data.desktop_environment)
        | .data.display_server = (($ov_ds | select($ov_ds_set == "1")) // .data.display_server)
        | .env.XDG_CURRENT_DESKTOP = ([ {"m": (.data.desktop_environment == "none"), "v": ""},
                                        {"m": (.data.desktop_environment == "gnome"), "v": "GNOME"},
                                        {"m": true, "v": .data.desktop_environment} ]
                                      | map(select(.m)) | .[0].v)
        | .env.XDG_SESSION_TYPE = .data.display_server
    '
}

# matrix_synthesize <base-image>... — build one ephemeral scenario per base
# image, using the OV_* overrides. Prints compact JSON records.
matrix_synthesize() {
    local mf
    mf="$(matrix_file)"
    local base distro suffix name
    for base in "$@"; do
        [ -n "$base" ] || continue
        distro="$(yq -r ".images[\"$base\"].distro" "$mf")"
        suffix="${OV_DE:-none}"
        [ -n "${OV_DS:-}" ] && suffix="${suffix}-${OV_DS}"
        suffix="${suffix}-${OV_FORM:-desktop}"
        name="ephemeral-${distro}-${suffix}"

        BASE_IMAGE="$base" \
        EPH_NAME="$name" \
        OV_FORM="${OV_FORM:-desktop}" \
        OV_DE="${OV_DE:-none}" \
        OV_DS="${OV_DS:-}" \
        OV_CATS="${OV_CATS:-}" \
            yq -o=json -I=0 '
            . as $root
            | (strenv(BASE_IMAGE)) as $img
            | ($root.images[$img]) as $i
            | ((strenv(OV_CATS)) | split(",") | map(select(. != ""))) as $cats
            | (strenv(OV_DE)) as $de
            | (strenv(OV_DS)) as $ds
            | {
                "name": strenv(EPH_NAME),
                "image": $img,
                "lane": $i.lane,
                "os": $i.os,
                "distro": $i.distro,
                "nix": ([ {"m": ($i.os == "linux"), "v": $root.defaults.nix}, {"m": true, "v": false} ]
                        | map(select(.m)) | .[0].v),
                "data": {
                  "categories": (($cats | select(length > 0)) // ["personal"]),
                  "form_factor": strenv(OV_FORM),
                  "desktop_environment": $de,
                  "display_server": $ds
                },
                "env": {
                  "XDG_CURRENT_DESKTOP": ([ {"m": ($de == "none"), "v": ""},
                                            {"m": ($de == "gnome"), "v": "GNOME"},
                                            {"m": true, "v": $de} ]
                                          | map(select(.m)) | .[0].v),
                  "XDG_SESSION_TYPE": $ds
                },
                "expect": {"apply_exit": 0}
              }
        ' "$mf"
    done
}

# matrix_default_image <distro> — default image for a distro id.
matrix_default_image() {
    yq -r ".defaults.distros[\"$1\"].default_image" "$(matrix_file)"
}

# matrix_image_exists <image>
matrix_image_exists() {
    yq -e ".images | has(\"$1\")" "$(matrix_file)" >/dev/null
}
