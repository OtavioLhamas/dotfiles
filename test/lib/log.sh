#!/usr/bin/env bash
# log.sh — run IDs, artifact directories, result recording, and summary output.
#
# Sourced by test/run.sh (and by the lint worker). Not executable on its own.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_BOLD=""
    C_DIM=""
fi

log_info() { printf '%s\n' "$*"; }
log_step() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# Escape a string for inclusion in a JSON string literal.
json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# log_init_run <stage> — set LOG_RUN_ID/LOG_RUN_DIR and create artifact dirs.
log_init_run() {
    local stage="$1"
    LOG_STAGE="$stage"
    LOG_RUN_ID="$(date +%Y-%m-%d-%H%M%S)-${stage}"
    LOG_RUN_DIR="${DOTFILES_TEST_RUNNER_DIR}/logs/${LOG_RUN_ID}"
    LOG_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "${LOG_RUN_DIR}/targets" "${LOG_RUN_DIR}/results"
    export LOG_STAGE LOG_RUN_ID LOG_RUN_DIR LOG_STARTED
}

log_target_file() { printf '%s/targets/%s.json' "$LOG_RUN_DIR" "$1"; }
log_result_dir() { printf '%s/results/%s' "$LOG_RUN_DIR" "$1"; }

# log_capture <logfile> <cmd...> — run cmd, write combined output to logfile,
# return the command's exit status. Never prints to the console.
log_capture() {
    local logfile="$1"
    shift
    mkdir -p "$(dirname "$logfile")"
    "$@" >"$logfile" 2>&1
}

# log_write_result <scenario> <stage> <status> <duration_s> <detail> [logfile]
log_write_result() {
    local scenario="$1" stage="$2" status="$3" duration="$4" detail="${5-}" logfile="${6-}"
    local dir rel=""
    dir="$(log_result_dir "$scenario")"
    mkdir -p "$dir"
    if [ -n "$logfile" ]; then
        rel="${logfile#"$LOG_RUN_DIR"/}"
    fi
    printf '{"scenario":"%s","stage":"%s","status":"%s","duration_s":%s,"detail":"%s","log":"%s"}\n' \
        "$(json_escape "$scenario")" "$(json_escape "$stage")" "$(json_escape "$status")" \
        "$duration" "$(json_escape "$detail")" "$(json_escape "$rel")" >"$dir/$stage.json"
}

# log_summary — aggregate results/*/result.json into summary.json and print a table.
log_summary() {
    local finished objs=() f line
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # results/<scenario>/ also holds JSON artifacts (DSC snapshots, chezmoi
    # state). Only stage result files carry a "stage" field.
    while IFS= read -r f; do
        grep -q '"stage"' "$f" 2>/dev/null || continue
        objs+=("$(cat "$f")")
    done < <(find "$LOG_RUN_DIR/results" -name '*.json' 2>/dev/null | sort)

    local results_json="[" first=1
    for line in "${objs[@]:-}"; do
        [ -n "$line" ] || continue
        [ "$first" -eq 1 ] || results_json+=","
        results_json+="$line"
        first=0
    done
    results_json+="]"

    local pass=0 fail=0 skip=0 warn=0 status
    for line in "${objs[@]:-}"; do
        [ -n "$line" ] || continue
        status="$(printf '%s' "$line" | yq -p=json -r '.status' 2>/dev/null || true)"
        case "$status" in
            pass) pass=$((pass + 1)) ;;
            fail) fail=$((fail + 1)) ;;
            skip) skip=$((skip + 1)) ;;
            warn) warn=$((warn + 1)) ;;
        esac
    done

    printf '{\n' >"$LOG_RUN_DIR/summary.json"
    printf '  "run_id": "%s",\n' "$(json_escape "$LOG_RUN_ID")" >>"$LOG_RUN_DIR/summary.json"
    printf '  "stage": "%s",\n' "$(json_escape "$LOG_STAGE")" >>"$LOG_RUN_DIR/summary.json"
    printf '  "started": "%s",\n' "$LOG_STARTED" >>"$LOG_RUN_DIR/summary.json"
    printf '  "finished": "%s",\n' "$finished" >>"$LOG_RUN_DIR/summary.json"
    printf '  "totals": {"pass": %d, "fail": %d, "skip": %d, "warn": %d},\n' \
        "$pass" "$fail" "$skip" "$warn" >>"$LOG_RUN_DIR/summary.json"
    printf '  "results": %s\n' "$results_json" >>"$LOG_RUN_DIR/summary.json"
    printf '}\n' >>"$LOG_RUN_DIR/summary.json"

    printf '\n%s%-40s %-8s %-7s %s%s\n' "$C_BOLD" "scenario" "stage" "status" "time" "$C_RESET"
    local scenario duration color stage_field
    for line in "${objs[@]:-}"; do
        [ -n "$line" ] || continue
        scenario="$(printf '%s' "$line" | yq -p=json -r '.scenario')"
        status="$(printf '%s' "$line" | yq -p=json -r '.status')"
        duration="$(printf '%s' "$line" | yq -p=json -r '.duration_s')"
        stage_field="$(printf '%s' "$line" | yq -p=json -r '.stage')"
        case "$status" in
            pass) color="$C_GREEN" ;;
            fail) color="$C_RED" ;;
            skip) color="$C_DIM" ;;
            *) color="$C_YELLOW" ;;
        esac
        printf '%-40s %-8s %s%-7s%s %ss\n' "$scenario" "$stage_field" "$color" "$status" "$C_RESET" "$duration"
    done
    printf '\n%s%d pass, %d fail, %d skip, %d warn%s\n' "$C_BOLD" "$pass" "$fail" "$skip" "$warn" "$C_RESET"
    printf '%sartifacts: %s%s\n' "$C_DIM" "$LOG_RUN_DIR" "$C_RESET"

    [ "$fail" -eq 0 ]
}
