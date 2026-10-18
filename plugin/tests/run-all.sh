#!/usr/bin/env bash
#
# Checks for plugin/: shellcheck over every shell script under plugin/, then
# each plugin/tests/*-test.sh. The pre-commit hook runs this when a commit
# touches plugin/; run it by hand from anywhere with `bash plugin/tests/run-all.sh`.
#
# Every check runs even after one fails, so one run reports every problem. The
# exit status is non-zero if any check failed, and the failures are named at the end.
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

failures=()

# A shell script is recognised by its shebang, so a new script in one of these
# directories is linted without anyone editing this file.
is_shell_script() {
    local first_line
    IFS= read -r first_line <"$1" || return 1
    case "$first_line" in
        '#!'*bash | '#!'*/sh | '#!'*' sh') return 0 ;;
    esac
    return 1
}

lint_plugin() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo -e "${RED}shellcheck is not installed.${NC} Install with: sudo apt install shellcheck" >&2
        failures+=("shellcheck (not installed)")
        return
    fi

    local -a scripts=()
    local candidate
    for candidate in plugin/bin/* plugin/hooks/* plugin/tests/*; do
        [ -f "$candidate" ] && is_shell_script "$candidate" && scripts+=("$candidate")
    done

    if [ ${#scripts[@]} -eq 0 ]; then
        echo "No shell scripts under plugin/ to lint."
        return
    fi

    echo "Linting ${#scripts[@]} plugin scripts..."
    shellcheck "${scripts[@]}" || failures+=("shellcheck")
}

run_tests() {
    local test
    for test in plugin/tests/*-test.sh; do
        [ -f "$test" ] || continue
        echo "Testing ${test}..."
        # git sets GIT_DIR and GIT_INDEX_FILE for hooks, which would point the
        # tests' throwaway repos at this checkout. Clear them for each test run.
        env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE bash "$test" || failures+=("$test")
    done
}

lint_plugin
run_tests

if [ ${#failures[@]} -gt 0 ]; then
    echo -e "${RED}plugin checks failed:${NC}" >&2
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi

echo -e "${GREEN}All plugin checks passed.${NC}"
