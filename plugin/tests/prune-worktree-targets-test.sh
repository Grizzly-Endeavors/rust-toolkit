#!/usr/bin/env bash
#
# Tests for hooks/prune-worktree-targets. Each case builds its own throwaway
# git repo with worktrees under .claude/worktrees/, ages files with `touch -t`,
# runs the hook, and checks what is left on disk and what it printed.
#
#   plugin/tests/prune-worktree-targets-test.sh
set -u

# A test run from a git hook inherits GIT_DIR and the other variables that point git
# at a repo, so its git commands would act on the enclosing repo. Clear them all.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CEILING_DIRECTORIES

TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$TESTS_DIR/../hooks/prune-worktree-targets"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/prune-worktree-targets-test.XXXXXX")" || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# Older than any idle window the cases use.
OLD_STAMP=202001010000

passed=0
failed=0
case_failed=0

fail() {
    printf '    FAIL: %s\n' "$*"
    case_failed=1
}

assert_exists() {
    [ -e "$1" ] || [ -L "$1" ] || fail "expected $1 to exist"
}

assert_missing() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "expected $1 to be deleted"
    fi
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

git_quiet() {
    git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main \
        -c advice.detachedHead=false "$@" >/dev/null 2>&1
}

# A main checkout at $CASE_DIR/main with one commit, ignoring .claude/ and
# target/ the way a real project would.
make_repo() {
    MAIN="$CASE_DIR/main"
    WORKTREES="$MAIN/.claude/worktrees"
    mkdir -p "$MAIN"
    (
        cd "$MAIN" || exit 1
        git_quiet init
        printf '/target\n/.claude/\n' >.gitignore
        printf 'fn main() {}\n' >main.rs
        git_quiet add .gitignore main.rs
        git_quiet commit -m init
    ) || fail "could not create the test repo"
    mkdir -p "$WORKTREES"
}

# Writes the CACHEDIR.TAG cargo puts in every target dir it creates.
tag_as_cargo() {
    printf '%s\n' 'Signature: 8a477f597d28d172789f06886806bc55' \
        '# This file is a cache directory tag created by cargo.' \
        '# For information about cache directory tags see https://bford.info/cachedir/' >"$1/CACHEDIR.TAG"
}

# A linked worktree at .claude/worktrees/<name> with a cargo-made target/
# holding a file.
add_worktree() {
    local name="$1"
    (cd "$MAIN" && git_quiet worktree add --detach "$WORKTREES/$name") \
        || fail "could not add worktree $name"
    mkdir -p "$WORKTREES/$name/target/debug"
    printf 'artifact\n' >"$WORKTREES/$name/target/debug/artifact"
    tag_as_cargo "$WORKTREES/$name/target"
}

# Age everything in a worktree outside target/, the worktree dir included.
age_worktree() {
    local dir="$1"
    (cd "$dir" && find . \( -path ./target -o -name .git \) -prune -o -exec touch -h -t "$OLD_STAMP" {} +) 2>/dev/null \
        || (cd "$dir" && find . \( -path ./target -o -name .git \) -prune -o -exec touch -t "$OLD_STAMP" {} +)
}

# Runs the hook from $1 with no stdin; leaves its stdout in $OUT and status in
# $STATUS.
run_hook_in() {
    local dir="$1"
    shift
    OUT="$(cd "$dir" && env TMPDIR="$CASE_DIR" "$@" "$HOOK" </dev/null 2>"$CASE_DIR/stderr")"
    STATUS=$?
}

assert_status_zero() {
    [ "$STATUS" -eq 0 ] || fail "hook exited $STATUS, expected 0"
}

assert_no_output() {
    [ -z "$OUT" ] || fail "expected no stdout, got: $OUT"
}

is_session_start_context() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$1" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | type == "string" and length > 0)' >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c 'import json, sys; o = json.load(sys.stdin)["hookSpecificOutput"]; sys.exit(0 if o["hookEventName"] == "SessionStart" and o["additionalContext"] else 1)' 2>/dev/null
    else
        fail "checking the summary JSON needs jq or python3"
        return 1
    fi
}

# One line of valid JSON whose additionalContext mentions every given name.
assert_summary_names() {
    local lines
    lines="$(printf '%s\n' "$OUT" | grep -c .)"
    [ "$lines" -eq 1 ] || fail "expected one summary line, got $lines: $OUT"
    is_session_start_context "$OUT" \
        || fail "summary is not a SessionStart additionalContext JSON line: $OUT"
    local name
    for name in "$@"; do
        case "$OUT" in
            *"$name"*) ;;
            *) fail "summary does not name $name: $OUT" ;;
        esac
    done
}

test_stale_worktree_target_removed() {
    make_repo
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_missing "$WORKTREES/stale/target"
    assert_exists "$WORKTREES/stale/main.rs"
    assert_exists "$WORKTREES/stale/.git"
    assert_summary_names stale
}

test_target_not_made_by_cargo_kept() {
    make_repo
    add_worktree untagged
    add_worktree other-tool
    add_worktree stale
    rm "$WORKTREES/untagged/target/CACHEDIR.TAG"
    printf 'Signature: 8a477f597d28d172789f06886806bc55\n# created by some other tool\n' \
        >"$WORKTREES/other-tool/target/CACHEDIR.TAG"
    age_worktree "$WORKTREES/untagged"
    age_worktree "$WORKTREES/other-tool"
    age_worktree "$WORKTREES/stale"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_exists "$WORKTREES/untagged/target/debug/artifact"
    assert_exists "$WORKTREES/other-tool/target/debug/artifact"
    assert_missing "$WORKTREES/stale/target"
    assert_summary_names stale
    case "$OUT" in
        *untagged* | *other-tool*) fail "summary names a kept worktree: $OUT" ;;
    esac
    grep -q "keeping .*untagged/target" "$CASE_DIR/stderr" || fail "no stderr note about the untagged target"
}

test_fresh_worktree_kept() {
    make_repo
    add_worktree fresh
    age_worktree "$WORKTREES/fresh"
    touch "$WORKTREES/fresh/main.rs"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_exists "$WORKTREES/fresh/target/debug/artifact"
    assert_no_output
}

test_recent_file_only_in_target_does_not_keep_it() {
    make_repo
    add_worktree built
    age_worktree "$WORKTREES/built"
    printf 'new\n' >"$WORKTREES/built/target/debug/just-built"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_missing "$WORKTREES/built/target"
    assert_summary_names built
}

test_symlinked_target_refused() {
    make_repo
    add_worktree linked
    rm -rf "$WORKTREES/linked/target"
    mkdir -p "$CASE_DIR/elsewhere"
    printf 'keep\n' >"$CASE_DIR/elsewhere/precious"
    tag_as_cargo "$CASE_DIR/elsewhere"
    ln -s "$CASE_DIR/elsewhere" "$WORKTREES/linked/target"
    age_worktree "$WORKTREES/linked"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_exists "$WORKTREES/linked/target"
    [ -L "$WORKTREES/linked/target" ] || fail "the target symlink was replaced"
    assert_exists "$CASE_DIR/elsewhere/precious"
    assert_no_output
}

test_symlinked_worktree_dir_refused() {
    make_repo
    mkdir -p "$CASE_DIR/outside/target"
    printf 'keep\n' >"$CASE_DIR/outside/target/precious"
    tag_as_cargo "$CASE_DIR/outside/target"
    printf 'src\n' >"$CASE_DIR/outside/main.rs"
    age_worktree "$CASE_DIR/outside"
    ln -s "$CASE_DIR/outside" "$WORKTREES/via-link"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_exists "$CASE_DIR/outside/target/precious"
    assert_no_output
}

test_symlinked_worktrees_dir_refused() {
    make_repo
    rmdir "$WORKTREES"
    mkdir -p "$CASE_DIR/real-worktrees/wt/target"
    printf 'keep\n' >"$CASE_DIR/real-worktrees/wt/target/precious"
    tag_as_cargo "$CASE_DIR/real-worktrees/wt/target"
    age_worktree "$CASE_DIR/real-worktrees/wt"
    ln -s "$CASE_DIR/real-worktrees" "$WORKTREES"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_exists "$CASE_DIR/real-worktrees/wt/target/precious"
    assert_no_output
}

test_pool_and_main_target_untouched() {
    make_repo
    mkdir -p "$MAIN/target/pool/0/debug" "$MAIN/target/debug"
    printf 'warm\n' >"$MAIN/target/pool/0/debug/artifact"
    printf 'main\n' >"$MAIN/target/debug/artifact"
    (cd "$MAIN" && find target -exec touch -t "$OLD_STAMP" {} +)
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_exists "$MAIN/target/pool/0/debug/artifact"
    assert_exists "$MAIN/target/debug/artifact"
    assert_missing "$WORKTREES/stale/target"
}

test_non_repo_cwd_is_noop() {
    mkdir -p "$CASE_DIR/plain/.claude/worktrees/wt/target"
    printf 'keep\n' >"$CASE_DIR/plain/.claude/worktrees/wt/target/precious"
    tag_as_cargo "$CASE_DIR/plain/.claude/worktrees/wt/target"
    age_worktree "$CASE_DIR/plain/.claude/worktrees/wt"
    # GIT_CEILING_DIRECTORIES keeps git from finding a repo above the scratch dir.
    run_hook_in "$CASE_DIR/plain" GIT_CEILING_DIRECTORIES="$CASE_DIR"
    assert_status_zero
    assert_no_output
    assert_exists "$CASE_DIR/plain/.claude/worktrees/wt/target/precious"
}

test_runs_from_inside_a_worktree() {
    make_repo
    add_worktree here
    add_worktree stale
    age_worktree "$WORKTREES/here"
    age_worktree "$WORKTREES/stale"
    run_hook_in "$WORKTREES/here"
    assert_status_zero
    assert_exists "$WORKTREES/here/target/debug/artifact"
    assert_missing "$WORKTREES/stale/target"
    assert_summary_names stale
}

test_stdin_cwd_used() {
    make_repo
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    mkdir -p "$CASE_DIR/elsewhere"
    OUT="$(cd "$CASE_DIR/elsewhere" \
        && printf '{"session_id":"s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$MAIN" \
        | env TMPDIR="$CASE_DIR" GIT_CEILING_DIRECTORIES="$CASE_DIR" "$HOOK" 2>/dev/null)"
    STATUS=$?
    assert_status_zero
    assert_missing "$WORKTREES/stale/target"
    assert_summary_names stale
}

# The same stdin case with jq absent from PATH, so the fallback parser runs.
test_stdin_cwd_used_without_jq() {
    make_repo
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    local bin="$CASE_DIR/bin" tool
    mkdir -p "$bin" "$CASE_DIR/elsewhere"
    for tool in bash env git cat tr sed find head cut du rm mkdir cksum awk kill basename dirname touch; do
        if command -v "$tool" >/dev/null 2>&1 && [ "$(command -v "$tool")" != "$tool" ]; then
            ln -s "$(command -v "$tool")" "$bin/$tool"
        fi
    done
    OUT="$(cd "$CASE_DIR/elsewhere" \
        && printf '{"session_id":"s",\n "cwd" : "%s"}' "$MAIN" \
        | env PATH="$bin" TMPDIR="$CASE_DIR" GIT_CEILING_DIRECTORIES="$CASE_DIR" "$bin/bash" "$HOOK" 2>/dev/null)"
    STATUS=$?
    assert_status_zero
    assert_missing "$WORKTREES/stale/target"
    assert_summary_names stale
}

test_prune_hours_override() {
    make_repo
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    # A window reaching back past the aged timestamps makes the worktree fresh.
    run_hook_in "$MAIN" TARGET_POOL_PRUNE_HOURS=1000000
    assert_status_zero
    assert_exists "$WORKTREES/stale/target/debug/artifact"
    assert_no_output
}

test_invalid_prune_hours_uses_default() {
    make_repo
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    run_hook_in "$MAIN" TARGET_POOL_PRUNE_HOURS=soon
    assert_status_zero
    assert_missing "$WORKTREES/stale/target"
    grep -q 'using 24' "$CASE_DIR/stderr" || fail "no stderr note about the invalid TARGET_POOL_PRUNE_HOURS"
}

test_live_lock_holder_skips_run() {
    make_repo
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    local key
    key="$(printf '%s' "$(cd "$MAIN" && pwd -P)" | cksum | cut -d' ' -f1)"
    mkdir -p "$CASE_DIR/rust-build-prune-$key.lock"
    printf '%s\n' "$$" >"$CASE_DIR/rust-build-prune-$key.lock/pid"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_exists "$WORKTREES/stale/target/debug/artifact"
    assert_no_output
}

test_stale_lock_recovered() {
    make_repo
    add_worktree stale
    age_worktree "$WORKTREES/stale"
    local key dead_pid
    key="$(printf '%s' "$(cd "$MAIN" && pwd -P)" | cksum | cut -d' ' -f1)"
    sh -c 'exit 0' &
    dead_pid=$!
    wait "$dead_pid"
    mkdir -p "$CASE_DIR/rust-build-prune-$key.lock"
    printf '%s\n' "$dead_pid" >"$CASE_DIR/rust-build-prune-$key.lock/pid"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_missing "$WORKTREES/stale/target"
    assert_missing "$CASE_DIR/rust-build-prune-$key.lock"
}

test_names_with_spaces_and_quotes() {
    make_repo
    add_worktree 'odd "name" here'
    age_worktree "$WORKTREES/odd \"name\" here"
    run_hook_in "$MAIN"
    assert_status_zero
    assert_missing "$WORKTREES/odd \"name\" here/target"
    assert_summary_names 'odd \"name\" here'
}

for test_case in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    run_case "$test_case"
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
