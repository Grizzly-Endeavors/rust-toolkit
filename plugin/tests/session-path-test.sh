#!/usr/bin/env bash
#
# Tests for hooks/session-path and the hook registration in hooks/hooks.json.
#
#   plugin/tests/session-path-test.sh
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
HOOK="$PLUGIN_DIR/hooks/session-path"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/session-path-test.XXXXXX")" || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

passed=0
failed=0
case_failed=0

fail() {
    printf '    FAIL: %s\n' "$*"
    case_failed=1
}

run_case() {
    local name="$1"
    case_failed=0
    CASE_DIR="$SCRATCH/$name"
    mkdir -p "$CASE_DIR"
    "$name"
    if [ "$case_failed" -eq 0 ]; then
        passed=$((passed + 1))
        printf 'ok   %s\n' "$name"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n' "$name"
    fi
}

# A stand-in plugin root at $1 whose bin/cargo identifies itself.
make_plugin_root() {
    mkdir -p "$1/bin"
    printf '#!/bin/sh\necho fake-cargo\n' >"$1/bin/cargo"
    chmod +x "$1/bin/cargo"
}

# Runs the hook with the given env assignments; stdout in $OUT, stderr in
# $ERR, status in $STATUS.
run_hook() {
    OUT="$(cd "$CASE_DIR" && env "$@" "$HOOK" </dev/null 2>"$CASE_DIR/stderr")"
    STATUS=$?
    ERR="$(cat "$CASE_DIR/stderr")"
}

# PATH as a bash that sources the env file would see it.
path_after_sourcing() {
    # shellcheck disable=SC2016 # $1 and $PATH expand in the child bash, not here
    env PATH="/usr/bin:/bin" "$BASH" -c '. "$1" && printf "%s" "$PATH"' _ "$1"
}

count_lines() {
    grep -c . "$1" 2>/dev/null || true
}

test_noop_without_env_file() {
    local root="$CASE_DIR/plugin"
    make_plugin_root "$root"
    run_hook -u CLAUDE_ENV_FILE CLAUDE_PLUGIN_ROOT="$root"
    [ "$STATUS" -eq 0 ] || fail "exited $STATUS, expected 0"
    [ -z "$OUT" ] || fail "expected no stdout, got: $OUT"
    local entry
    for entry in "$CASE_DIR"/* "$CASE_DIR"/.[!.]*; do
        case "${entry##*/}" in
            plugin | stderr | '*' | '.[!.]*') ;;
            *) fail "wrote $entry with no CLAUDE_ENV_FILE set" ;;
        esac
    done
}

test_appends_export_line() {
    local root="$CASE_DIR/plugin" env_file="$CASE_DIR/env.sh"
    make_plugin_root "$root"
    printf 'export EXISTING=1\n' >"$env_file"
    run_hook CLAUDE_ENV_FILE="$env_file" CLAUDE_PLUGIN_ROOT="$root"
    [ "$STATUS" -eq 0 ] || fail "exited $STATUS, expected 0: $ERR"
    [ -z "$OUT" ] || fail "expected no stdout, got: $OUT"
    grep -qx 'export EXISTING=1' "$env_file" || fail "existing env file content was lost"
    [ "$(count_lines "$env_file")" -eq 2 ] || fail "expected one line appended: $(cat "$env_file")"
    grep -q '^export PATH=' "$env_file" || fail "no export PATH line: $(cat "$env_file")"
    local path
    path="$(path_after_sourcing "$env_file")"
    [ "$path" = "$root/bin:/usr/bin:/bin" ] || fail "PATH after sourcing is $path"
    [ "$(env PATH="$path" sh -c 'command -v cargo')" = "$root/bin/cargo" ] \
        || fail "cargo does not resolve to the plugin's bin/cargo"
}

test_repeat_runs_add_one_line() {
    local root="$CASE_DIR/plugin" env_file="$CASE_DIR/env.sh"
    make_plugin_root "$root"
    run_hook CLAUDE_ENV_FILE="$env_file" CLAUDE_PLUGIN_ROOT="$root"
    run_hook CLAUDE_ENV_FILE="$env_file" CLAUDE_PLUGIN_ROOT="$root"
    run_hook CLAUDE_ENV_FILE="$env_file" CLAUDE_PLUGIN_ROOT="$root"
    [ "$STATUS" -eq 0 ] || fail "exited $STATUS, expected 0: $ERR"
    [ "$(count_lines "$env_file")" -eq 1 ] || fail "expected one line after three runs: $(cat "$env_file")"
}

test_path_with_special_characters() {
    local root="$CASE_DIR/it's a \$HOME \"plugin\"" env_file="$CASE_DIR/env.sh"
    make_plugin_root "$root"
    run_hook CLAUDE_ENV_FILE="$env_file" CLAUDE_PLUGIN_ROOT="$root"
    [ "$STATUS" -eq 0 ] || fail "exited $STATUS, expected 0: $ERR"
    local path
    path="$(path_after_sourcing "$env_file")"
    [ "$path" = "$root/bin:/usr/bin:/bin" ] || fail "PATH after sourcing is $path"
}

test_falls_back_to_script_dir() {
    local env_file="$CASE_DIR/env.sh"
    run_hook -u CLAUDE_PLUGIN_ROOT CLAUDE_ENV_FILE="$env_file"
    [ "$STATUS" -eq 0 ] || fail "exited $STATUS, expected 0: $ERR"
    local path
    path="$(path_after_sourcing "$env_file")"
    [ "$path" = "$PLUGIN_DIR/bin:/usr/bin:/bin" ] || fail "PATH after sourcing is $path"
}

test_unwritable_env_file_reports_error() {
    local root="$CASE_DIR/plugin"
    make_plugin_root "$root"
    run_hook CLAUDE_ENV_FILE="$CASE_DIR/missing-dir/env.sh" CLAUDE_PLUGIN_ROOT="$root"
    [ "$STATUS" -ne 0 ] || fail "exited 0 although the env file could not be written"
    [ -z "$OUT" ] || fail "expected no stdout, got: $OUT"
    case "$ERR" in
        *CLAUDE_ENV_FILE*) ;;
        *) fail "stderr does not explain the failure: $ERR" ;;
    esac
}

# The registration: valid JSON, both scripts on SessionStart for every source
# (no matcher), session-path synchronous, the prune async, and every command
# naming an executable script in this plugin.
test_hooks_json_registration() {
    local checker
    if command -v python3 >/dev/null 2>&1; then
        checker="$(
            python3 - "$HOOKS_JSON" <<'EOF'
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["SessionStart"]
for group in groups:
    matcher = group.get("matcher", "")
    for hook in group["hooks"]:
        print("%s\t%s\t%s\t%s" % (hook["type"], hook["command"], str(hook.get("async", False)).lower(), matcher))
EOF
        )" || fail "hooks.json is not valid JSON in the expected shape"
    elif command -v jq >/dev/null 2>&1; then
        checker="$(jq -r '.hooks.SessionStart[] | (.matcher // "") as $m | .hooks[] | [.type, .command, (.async // false | tostring), $m] | @tsv' "$HOOKS_JSON")" \
            || fail "hooks.json is not valid JSON in the expected shape"
    else
        fail "checking hooks.json needs python3 or jq"
        return
    fi

    local found_path="" found_prune=""
    local type command async matcher script
    while IFS="$(printf '\t')" read -r type command async matcher; do
        [ -n "$type" ] || continue
        [ "$type" = "command" ] || fail "hook type is $type, expected command"
        [ -z "$matcher" ] || fail "matcher '$matcher' limits the sources the hooks run on"
        # shellcheck disable=SC2016 # matching the literal ${CLAUDE_PLUGIN_ROOT} text in hooks.json
        case "$command" in
            '"${CLAUDE_PLUGIN_ROOT}/'*'"') ;;
            *) fail "command is not a quoted \${CLAUDE_PLUGIN_ROOT} path: $command" ;;
        esac
        script="${command#\"\$\{CLAUDE_PLUGIN_ROOT\}/}"
        script="${script%\"}"
        [ -x "$PLUGIN_DIR/$script" ] || fail "$script is not an executable file in the plugin"
        case "$script" in
            hooks/session-path)
                found_path=1
                [ "$async" = "false" ] || fail "session-path must run synchronously"
                ;;
            hooks/prune-worktree-targets)
                found_prune=1
                [ "$async" = "true" ] || fail "prune-worktree-targets should run async"
                ;;
        esac
    done <<EOF
$checker
EOF
    [ -n "$found_path" ] || fail "session-path is not registered on SessionStart"
    [ -n "$found_prune" ] || fail "prune-worktree-targets is not registered on SessionStart"
}

for test_case in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    run_case "$test_case"
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
