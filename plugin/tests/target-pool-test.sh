#!/usr/bin/env bash
# Tests for bin/target-pool and the bin/cargo wrapper. Self-contained: builds throwaway
# git repos in a temp dir and puts a stub "real cargo" on PATH after the wrapper.
#
#   bash plugin/tests/target-pool-test.sh
#
# The lock tests run under every lock mechanism this machine has (flock and mkdir), or
# only the one TARGET_POOL_LOCK_IMPL names. The real-cargo regression test is skipped
# when cargo is not installed.

set -u

tests_dir=$(cd "$(dirname "$0")" && pwd -P)
plugin_bin=$(cd "$tests_dir/../bin" && pwd -P)
original_path=$PATH

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/target-pool-test.XXXXXX") || exit 1
tmp_root=$(cd "$tmp_root" && pwd -P)
stub_bin=$tmp_root/stub-bin
mkdir -p "$stub_bin"
cp "$tests_dir/stub-cargo" "$stub_bin/cargo"
chmod +x "$stub_bin/cargo"

export PATH="$plugin_bin:$stub_bin:$original_path"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CEILING_DIRECTORIES=$tmp_root
unset CARGO_TARGET_DIR CARGO_BUILD_BUILD_DIR TARGET_POOL_SIZE TARGET_POOL_CAP_GB TARGET_POOL_CAP_KB TARGET_POOL_DISABLE

started_pids=$tmp_root/started-pids
cleanup() {
	local pid
	if [ -f "$started_pids" ]; then
		while read -r pid; do
			kill -9 -- "-$pid" 2>/dev/null
			kill -9 "$pid" 2>/dev/null
		done <"$started_pids"
	fi
	rm -rf "$tmp_root"
}
trap cleanup EXIT

# --- harness ---------------------------------------------------------------------------

fail() {
	printf '    %s\n' "$*" >&2
	return 1
}

now() { date +%s; }

# wait_until <seconds> <command...>: polls until the command succeeds; fails on timeout.
wait_until() {
	local deadline=$(($(now) + $1))
	shift
	until "$@"; do
		[ "$(now)" -le "$deadline" ] || return 1
		sleep 0.05
	done
}

not_running() { ! kill -0 "$1" 2>/dev/null; }

in_dir() {
	cd "$1" || exit 1
	shift
	exec "$@"
}

# start_bg <out> <err> <command...>: runs the command as a job in its own process group,
# so it starts with default SIGINT handling, and sets bg_pid.
start_bg() {
	local out=$1 err=$2
	shift 2
	set -m
	"$@" </dev/null >"$out" 2>"$err" &
	bg_pid=$!
	set +m
	printf '%s\n' "$bg_pid" >>"$started_pids"
}

# await_exit <pid> <seconds>: waits for a start_bg job and sets bg_status; kills it and
# fails when it outlives the timeout.
await_exit() {
	if ! wait_until "$2" not_running "$1"; then
		kill -9 -- "-$1" 2>/dev/null
		kill -9 "$1" 2>/dev/null
		wait "$1" 2>/dev/null
		fail "process $1 still running after $2s"
		return 1
	fi
	wait "$1"
	bg_status=$?
}

# run_in <dir> <command...>: runs to completion (bounded) with output in $case_dir/out
# and $case_dir/err, and sets run_status.
run_in() {
	local dir=$1
	shift
	start_bg "$case_dir/out" "$case_dir/err" in_dir "$dir" "$@"
	await_exit "$bg_pid" 30 || {
		fail "timed out: $*"
		return 1
	}
	run_status=$bg_status
}

last_logged_target() {
	tail -n 1 "$STUB_LOG" | sed 's/^pid=[0-9]* target=\(.*\) args=.*$/\1/'
}

expect_eq() {
	[ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

expect_status() {
	[ "$run_status" -eq "$1" ] || fail "$2: expected exit $1, got $run_status; stderr: $(cat "$case_dir/err")"
}

expect_no_stderr() {
	[ ! -s "$case_dir/err" ] || fail "$1: unexpected stderr: $(cat "$case_dir/err")"
}

file_contains() { [ -f "$1" ] && grep -q -- "$2" "$1"; }

# new_repo: a repo with three linked worktrees; sets repo, wt1, wt2, wt3 and pool.
new_repo() {
	local base=$case_dir/repo
	mkdir -p "$base/main"
	(
		cd "$base/main" &&
			git -c init.defaultBranch=main init -q &&
			git commit -q --allow-empty -m init &&
			git worktree add -q ../wt1 &&
			git worktree add -q ../wt2 &&
			git worktree add -q ../wt3
	) || fail "couldn't create test repo in $base"
	repo=$base/main
	wt1=$base/wt1
	wt2=$base/wt2
	wt3=$base/wt3
	pool=$repo/target/pool
}

slot_state() { # <dir> <slot>: the status line for one slot
	(cd "$1" && target-pool status) | awk -v slot="$2" '$1 == slot'
}

slot_is_free() { slot_state "$1" "$2" | grep -q ' free '; }

# --- tests: wrapper and pass-through ------------------------------------------------------

test_lease_and_release() {
	new_repo
	run_in "$wt1" cargo build || return 1
	expect_status 0 "build" || return 1
	expect_eq "$pool/0" "$(last_logged_target)" "leased dir" || return 1
	expect_no_stderr "build" || return 1
	slot_is_free "$wt1" 0 || fail "slot 0 still leased after the run: $(slot_state "$wt1" 0)" || return 1
	slot_state "$wt1" 0 | grep -q "last used by $wt1\$" || fail "status doesn't name the last worktree: $(slot_state "$wt1" 0)" || return 1
	expect_eq "$pool" "$(cd "$wt2" && target-pool path)" "pool path from a worktree" || return 1
	expect_eq "$pool" "$(cd "$repo" && target-pool path)" "pool path from the main checkout"
}

test_pass_through_when_target_dir_set() {
	new_repo
	run_in "$wt1" env CARGO_TARGET_DIR="$case_dir/own" cargo build || return 1
	expect_status 0 "build" || return 1
	expect_eq "$case_dir/own" "$(last_logged_target)" "CARGO_TARGET_DIR kept" || return 1
	run_in "$wt1" env CARGO_BUILD_BUILD_DIR="$case_dir/build" cargo build || return 1
	expect_eq "<unset>" "$(last_logged_target)" "no lease with CARGO_BUILD_BUILD_DIR" || return 1
	[ ! -d "$pool" ] || fail "pool created despite pass-through"
}

test_pass_through_non_build_and_outside_repo() {
	new_repo
	local args
	for args in "metadata --no-deps" "--version" "fmt" "+nightly --list" "clean"; do
		# shellcheck disable=SC2086 # args is a word list
		run_in "$wt1" cargo $args || return 1
		expect_eq "<unset>" "$(last_logged_target)" "cargo $args passes through" || return 1
	done
	[ ! -d "$pool" ] || fail "pool created by a non-build command" || return 1
	mkdir -p "$case_dir/not-a-repo"
	run_in "$case_dir/not-a-repo" cargo build || return 1
	expect_status 0 "build outside a repo" || return 1
	expect_eq "<unset>" "$(last_logged_target)" "outside a repo passes through" || return 1
	run_in "$wt1" env TARGET_POOL_DISABLE=1 cargo build || return 1
	expect_eq "<unset>" "$(last_logged_target)" "TARGET_POOL_DISABLE=1 passes through"
}

test_global_options_before_subcommand() {
	new_repo
	local args
	for args in "+nightly -q --color always build" "--config build.jobs=2 -Zfoo t" "-vv -C . clippy" "--locked --offline nextest run" "c"; do
		# shellcheck disable=SC2086 # args is a word list
		run_in "$wt1" cargo $args || return 1
		expect_eq "$pool/0" "$(last_logged_target)" "cargo $args leases" || return 1
	done
}

test_explicit_target_dir() {
	new_repo
	run_in "$wt1" cargo build --target-dir "$case_dir/x" || return 1
	expect_eq "<unset>" "$(last_logged_target)" "--target-dir X passes through" || return 1
	run_in "$wt1" cargo build --target-dir="$case_dir/x" || return 1
	expect_eq "<unset>" "$(last_logged_target)" "--target-dir=X passes through" || return 1
	run_in "$wt1" cargo run -- --target-dir x || return 1
	expect_eq "$pool/0" "$(last_logged_target)" "--target-dir after -- belongs to the program"
}

test_nested_cargo_inherits_lease() {
	new_repo
	run_in "$wt1" env STUB_NESTED=1 cargo build || return 1
	expect_status 0 "nested build" || return 1
	expect_eq 2 "$(wc -l <"$STUB_LOG" | tr -d ' ')" "stub calls (outer and inner)" || return 1
	grep -q "target=$pool/0 args=build --inner\$" "$STUB_LOG" || fail "inner cargo didn't inherit the lease: $(cat "$STUB_LOG")"
}

test_finds_real_cargo() {
	new_repo
	mkdir -p "$case_dir/copy-bin" "$case_dir/link-bin" "$case_dir/tools"
	cp "$plugin_bin/cargo" "$plugin_bin/target-pool" "$case_dir/copy-bin/"
	ln -s "$plugin_bin/cargo" "$case_dir/link-bin/cargo"
	local crowded="$case_dir/copy-bin:$plugin_bin:$case_dir/link-bin:$plugin_bin:$stub_bin:$original_path"
	run_in "$wt1" env PATH="$crowded" cargo build || return 1
	expect_status 0 "build with wrappers repeated on PATH" || return 1
	expect_eq 1 "$(wc -l <"$STUB_LOG" | tr -d ' ')" "stub calls" || return 1
	expect_eq "$pool/0" "$(last_logged_target)" "leased dir" || return 1

	local tool
	for tool in bash readlink grep; do
		ln -s "$(command -v "$tool")" "$case_dir/tools/$tool"
	done
	run_in "$wt1" env PATH="$plugin_bin:$case_dir/link-bin:$case_dir/tools" cargo build || return 1
	expect_status 127 "no real cargo" || return 1
	grep -q "no real cargo found" "$case_dir/err" || fail "missing explanation: $(cat "$case_dir/err")"
}

test_exit_status_passthrough() {
	new_repo
	run_in "$wt1" env STUB_EXIT=3 cargo test || return 1
	expect_status 3 "STUB_EXIT=3" || return 1
	run_in "$wt1" env STUB_SELF_SIGNAL=INT cargo test || return 1
	expect_status 130 "child dies of SIGINT" || return 1
	slot_is_free "$wt1" 0 || fail "slot 0 still leased: $(slot_state "$wt1" 0)"
}

test_settings_validation() {
	new_repo
	run_in "$wt1" env TARGET_POOL_SIZE=0 cargo build || return 1
	expect_status 1 "TARGET_POOL_SIZE=0" || return 1
	grep -q TARGET_POOL_SIZE "$case_dir/err" || fail "error doesn't name TARGET_POOL_SIZE" || return 1
	run_in "$wt1" env TARGET_POOL_CAP_GB=lots cargo build || return 1
	expect_status 1 "TARGET_POOL_CAP_GB=lots" || return 1
	[ ! -f "$STUB_LOG" ] || fail "command ran despite bad settings"
}

test_pool_creation_failure() {
	new_repo
	printf 'not a dir\n' >"$repo/target"
	run_in "$wt1" cargo build || return 1
	expect_status 1 "unwritable pool" || return 1
	grep -q "couldn't create the build dir pool" "$case_dir/err" || fail "missing explanation: $(cat "$case_dir/err")" || return 1
	[ ! -f "$STUB_LOG" ] || fail "command ran cold instead of failing"
}

test_status_outside_repo() {
	mkdir -p "$case_dir/not-a-repo"
	run_in "$case_dir/not-a-repo" target-pool status || return 1
	expect_status 1 "status outside a repo" || return 1
	grep -q "not inside a git work tree" "$case_dir/err" || fail "missing explanation: $(cat "$case_dir/err")"
}

workspace_metadata_json() { # <id format> <worktree>: metadata with members app and my-lib
	local root=$2
	case $1 in
		new) printf '{"packages":[],"workspace_members":["path+file://%s/app#0.1.0","path+file://%s/crates/lib#my-lib@0.2.0"],"workspace_root":"%s"}\n' "$root" "$root" "$root" ;;
		old) printf '{"packages":[],"workspace_members":["app 0.1.0 (path+file://%s/app)","my-lib 0.2.0 (path+file://%s/crates/lib)"],"workspace_root":"%s"}\n' "$root" "$root" "$root" ;;
	esac
}

fingerprints_left() { # <slot dir>: unit dirs left in its fingerprint dirs, sorted
	(cd "$1" && find . -path '*/.fingerprint/*' -prune -print | sed 's|.*/\.fingerprint/||' | sort -u | tr '\n' ' ')
}

test_hand_off_clears_member_fingerprints() {
	export TARGET_POOL_SIZE=1
	local format units="app-1111 my-lib-2222 my_lib-3333 serde-4444 other-5555"
	for format in new old; do
		rm -rf "$case_dir/repo" "$STUB_LOG"
		new_repo
		workspace_metadata_json "$format" "$wt2" >"$case_dir/metadata.json"
		run_in "$wt1" env STUB_FINGERPRINTS="$units" cargo build || return 1
		run_in "$wt1" env STUB_METADATA="$case_dir/metadata.json" cargo build || return 1
		expect_eq "app-1111 my-lib-2222 my_lib-3333 other-5555 serde-4444 " "$(fingerprints_left "$pool/0")" "$format ids: same-worktree reuse keeps fingerprints" || return 1
		run_in "$wt2" env STUB_METADATA="$case_dir/metadata.json" cargo build || return 1
		expect_status 0 "$format ids: hand-off build" || return 1
		expect_no_stderr "$format ids: hand-off" || return 1
		expect_eq "$pool/0" "$(last_logged_target)" "$format ids: wt2 got the warm dir" || return 1
		expect_eq "other-5555 serde-4444 " "$(fingerprints_left "$pool/0")" "$format ids: members cleared, deps kept" || return 1
	done

	run_in "$wt2" env STUB_FINGERPRINTS="$units" cargo build || return 1
	run_in "$wt3" cargo build || return 1
	expect_status 0 "hand-off with failing metadata" || return 1
	grep -q "couldn't list this worktree's workspace members" "$case_dir/err" || fail "fallback not reported: $(cat "$case_dir/err")" || return 1
	expect_eq "" "$(fingerprints_left "$pool/0")" "metadata failure clears every fingerprint"
}

test_signal_forwarding() {
	new_repo
	local sig number
	for sig in INT TERM HUP QUIT; do
		case $sig in INT) number=2 ;; TERM) number=15 ;; HUP) number=1 ;; QUIT) number=3 ;; esac
		rm -f "$case_dir/ready" "$case_dir/siglog"
		start_bg "$case_dir/out" "$case_dir/err" in_dir "$wt1" env STUB_TRAP=1 STUB_SIGLOG="$case_dir/siglog" \
			STUB_READY="$case_dir/ready" STUB_HOLD="$case_dir/never" cargo build
		wait_until 15 test -e "$case_dir/ready" || fail "$sig: stub never started" || return 1
		kill -s "$sig" "$bg_pid"
		await_exit "$bg_pid" 15 || fail "$sig: target-pool didn't exit after the signal" || return 1
		expect_eq $((128 + number)) "$bg_status" "$sig: exit status" || return 1
		file_contains "$case_dir/siglog" "$sig" || fail "$sig: stub never saw the signal" || return 1
		slot_is_free "$wt1" 0 || fail "$sig: slot 0 still leased: $(slot_state "$wt1" 0)" || return 1
	done
}

test_terminal_runs_in_foreground() {
	if ! script -qec true /dev/null >/dev/null 2>&1; then
		printf '    skipped: util-linux script(1) not available\n'
		return 0
	fi
	new_repo
	local command="cd '$wt1' && STUB_READ_STDIN='$case_dir/read' cargo build"
	# shellcheck disable=SC2016 # $1 is expanded by the inner sh
	start_bg "$case_dir/out" "$case_dir/err" sh -c 'printf "hello\n" | exec script -qec "$1" /dev/null' sh "$command"
	await_exit "$bg_pid" 15 || fail "a command reading the terminal got stuck" || return 1
	expect_eq 0 "$bg_status" "exit status under a terminal" || return 1
	expect_eq hello "$(cat "$case_dir/read" 2>/dev/null)" "line read from the terminal" || return 1
	expect_eq "$pool/0" "$(last_logged_target)" "leased dir"
}

# --- tests: locking (run per lock mechanism) ------------------------------------------------

test_concurrent_runs_get_different_dirs() {
	new_repo
	start_bg "$case_dir/a.out" "$case_dir/a.err" in_dir "$wt1" env STUB_READY="$case_dir/a.ready" STUB_HOLD="$case_dir/go" cargo build
	local a=$bg_pid
	start_bg "$case_dir/b.out" "$case_dir/b.err" in_dir "$wt2" env STUB_READY="$case_dir/b.ready" STUB_HOLD="$case_dir/go" cargo build
	local b=$bg_pid
	wait_until 15 test -e "$case_dir/a.ready" -a -e "$case_dir/b.ready" || fail "runs never started" || return 1
	local dir_a dir_b
	dir_a=$(cat "$case_dir/a.ready")
	dir_b=$(cat "$case_dir/b.ready")
	[ "$dir_a" != "$dir_b" ] || fail "both runs leased $dir_a" || return 1
	case "$dir_a $dir_b" in "$pool/"[0-3]" $pool/"[0-3]) ;; *) fail "dirs outside the pool: $dir_a $dir_b" || return 1 ;; esac
	(cd "$wt1" && target-pool status) | grep -q "leased by pid $a " || fail "status doesn't show holder $a: $(cd "$wt1" && target-pool status)" || return 1
	touch "$case_dir/go"
	await_exit "$a" 15 && expect_eq 0 "$bg_status" "first run" || return 1
	await_exit "$b" 15 && expect_eq 0 "$bg_status" "second run"
}

test_waits_when_all_busy() {
	new_repo
	export TARGET_POOL_SIZE=2
	start_bg "$case_dir/a.out" "$case_dir/a.err" in_dir "$wt1" env STUB_READY="$case_dir/a.ready" STUB_HOLD="$case_dir/go-a" cargo build
	local a=$bg_pid
	start_bg "$case_dir/b.out" "$case_dir/b.err" in_dir "$wt2" env STUB_READY="$case_dir/b.ready" STUB_HOLD="$case_dir/go-b" cargo build
	local b=$bg_pid
	wait_until 15 test -e "$case_dir/a.ready" -a -e "$case_dir/b.ready" || fail "holders never started" || return 1
	start_bg "$case_dir/c.out" "$case_dir/c.err" in_dir "$wt3" env STUB_READY="$case_dir/c.ready" cargo build
	local c=$bg_pid
	wait_until 15 file_contains "$case_dir/c.err" "waiting" || fail "third run never said it was waiting" || return 1
	# Proving the third run stays blocked, and announces it only once, takes time passing.
	sleep 1.2
	[ ! -e "$case_dir/c.ready" ] || fail "third run started while both dirs were leased" || return 1
	touch "$case_dir/go-a"
	await_exit "$a" 15 || return 1
	await_exit "$c" 15 || fail "third run didn't proceed once a dir freed" || return 1
	expect_eq 0 "$bg_status" "third run" || return 1
	expect_eq "$(cat "$case_dir/a.ready")" "$(cat "$case_dir/c.ready")" "third run took the freed dir" || return 1
	expect_eq 1 "$(wc -l <"$case_dir/c.err" | tr -d ' ')" "stderr lines from the waiting run" || return 1
	grep -q "all 2 build dirs" "$case_dir/c.err" && grep -q "target-pool status" "$case_dir/c.err" ||
		fail "wait line should name the pool size and target-pool status: $(cat "$case_dir/c.err")" || return 1
	touch "$case_dir/go-b"
	await_exit "$b" 15
}

test_affinity() {
	new_repo
	export TARGET_POOL_SIZE=3
	run_in "$wt2" cargo build && expect_eq "$pool/0" "$(last_logged_target)" "wt2's first run" || return 1
	run_in "$wt1" cargo build && expect_eq "$pool/1" "$(last_logged_target)" "wt1 takes an unclaimed dir" || return 1
	run_in "$wt1" cargo build && expect_eq "$pool/1" "$(last_logged_target)" "wt1 gets its dir back" || return 1
	run_in "$wt3" cargo build && expect_eq "$pool/2" "$(last_logged_target)" "wt3 takes the unclaimed dir" || return 1
	run_in "$wt2" cargo build && expect_eq "$pool/0" "$(last_logged_target)" "wt2 gets its dir back" || return 1

	start_bg "$case_dir/a.out" "$case_dir/a.err" in_dir "$wt1" env STUB_READY="$case_dir/a.ready" STUB_HOLD="$case_dir/go" cargo build
	local a=$bg_pid
	wait_until 15 test -e "$case_dir/a.ready" || fail "holder never started" || return 1
	expect_eq "$pool/1" "$(cat "$case_dir/a.ready")" "wt1 holds its dir" || return 1
	run_in "$wt1" cargo build || return 1
	expect_status 0 "second wt1 run" || return 1
	[ "$(last_logged_target)" != "$pool/1" ] || fail "second wt1 run shared a leased dir" || return 1
	touch "$case_dir/go"
	await_exit "$a" 15
}

test_size_cap() {
	new_repo
	run_in "$wt1" env TARGET_POOL_CAP_KB=1024 STUB_FILL_KB=16 cargo build || return 1
	expect_no_stderr "under the cap" || return 1
	[ -f "$pool/0/fill" ] || fail "dir emptied while under the cap" || return 1
	run_in "$wt1" env TARGET_POOL_CAP_KB=64 STUB_FILL_KB=256 cargo build || return 1
	expect_status 0 "over the cap" || return 1
	[ -d "$pool/0" ] || fail "dir removed instead of emptied" || return 1
	expect_eq "" "$(ls -A "$pool/0")" "dir contents after the cap clean" || return 1
	expect_eq 1 "$(wc -l <"$case_dir/err" | tr -d ' ')" "stderr lines" || return 1
	grep -q "over the 64 KB cap" "$case_dir/err" || fail "cap line should give the cap: $(cat "$case_dir/err")" || return 1
	slot_is_free "$wt1" 0 || fail "slot 0 still leased after the clean"
}

test_background_process_does_not_keep_lease() {
	new_repo
	export TARGET_POOL_SIZE=1
	run_in "$wt1" env STUB_DAEMON="$case_dir/daemon.pid" cargo test || return 1
	expect_status 0 "run that leaves a daemon" || return 1
	local daemon
	daemon=$(cat "$case_dir/daemon.pid")
	printf '%s\n' "$daemon" >>"$started_pids"
	kill -0 "$daemon" 2>/dev/null || fail "daemon isn't running, so the test proves nothing" || return 1
	run_in "$wt2" cargo build || return 1
	expect_status 0 "next run" || return 1
	expect_no_stderr "next run (it must not wait)" || return 1
	expect_eq "$pool/0" "$(last_logged_target)" "next run got the dir" || return 1
	kill "$daemon"
}

test_stale_mkdir_lock_recovery() {
	new_repo
	export TARGET_POOL_SIZE=1 TARGET_POOL_LOCK_IMPL=mkdir
	mkdir -p "$pool/.locks/0.lockdir"
	sh -c 'exit 0' &
	local dead=$!
	wait "$dead"
	printf '%s\n' "$dead" >"$pool/.locks/0.lockdir/pid"
	run_in "$wt1" cargo build || return 1
	expect_status 0 "lock left by a dead PID" || return 1
	expect_no_stderr "dead PID lock (it must not wait)" || return 1
	[ ! -d "$pool/.locks/0.lockdir" ] || fail "lockdir left behind after release" || return 1

	mkdir "$pool/.locks/0.lockdir"
	touch -t 200001010000 "$pool/.locks/0.lockdir"
	run_in "$wt1" cargo build || return 1
	expect_no_stderr "old lock without a PID (it must not wait)" || return 1

	sleep 300 &
	local holder=$!
	printf '%s\n' "$holder" >>"$started_pids"
	mkdir "$pool/.locks/0.lockdir"
	printf '%s\n' "$holder" >"$pool/.locks/0.lockdir/pid"
	slot_state "$wt1" 0 | grep -q "leased by pid $holder " || fail "status doesn't show the mkdir holder: $(slot_state "$wt1" 0)" || return 1
	start_bg "$case_dir/c.out" "$case_dir/c.err" in_dir "$wt1" cargo build
	local c=$bg_pid
	wait_until 15 file_contains "$case_dir/c.err" "waiting" || fail "run didn't wait for a live holder" || return 1
	kill "$holder"
	wait "$holder" 2>/dev/null
	await_exit "$c" 15 || fail "run didn't recover the lock after its holder died" || return 1
	expect_eq 0 "$bg_status" "run after the holder died"
}

# A holder under one mechanism blocks a run under the other.
test_mechanisms_agree() {
	new_repo
	export TARGET_POOL_SIZE=1
	local first second
	for first in flock mkdir; do
		case $first in flock) second='mkdir' ;; mkdir) second='flock' ;; esac
		rm -f "$case_dir/ready" "$case_dir/go" "$case_dir/b.ready"
		start_bg "$case_dir/a.out" "$case_dir/a.err" in_dir "$wt1" env TARGET_POOL_LOCK_IMPL=$first \
			STUB_READY="$case_dir/ready" STUB_HOLD="$case_dir/go" cargo build
		local a=$bg_pid
		wait_until 15 test -e "$case_dir/ready" || fail "$first holder never started" || return 1
		(cd "$wt1" && TARGET_POOL_LOCK_IMPL=$second target-pool status) | grep -q "leased by pid $a " ||
			fail "$second status doesn't see the $first holder" || return 1
		start_bg "$case_dir/b.out" "$case_dir/b.err" in_dir "$wt2" env TARGET_POOL_LOCK_IMPL=$second \
			STUB_READY="$case_dir/b.ready" cargo build
		local b=$bg_pid
		wait_until 15 file_contains "$case_dir/b.err" "waiting" || fail "$second run didn't wait for the $first holder" || return 1
		[ ! -e "$case_dir/b.ready" ] || fail "$second run shared the dir" || return 1
		touch "$case_dir/go"
		await_exit "$a" 15 || return 1
		await_exit "$b" 15 && expect_eq 0 "$bg_status" "$second run after release" || return 1
	done
}

# --- test: real cargo -------------------------------------------------------------------------

write_two_crate_workspace() { # <dir> <greeting>
	mkdir -p "$1/app/src" "$1/greeting/src"
	printf '[workspace]\nmembers = ["app", "greeting"]\nresolver = "2"\n' >"$1/Cargo.toml"
	printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\ngreeting = { path = "../greeting" }\n' >"$1/app/Cargo.toml"
	printf 'fn main() {\n    println!("{}", greeting::text());\n}\n' >"$1/app/src/main.rs"
	printf '[package]\nname = "greeting"\nversion = "0.1.0"\nedition = "2021"\n' >"$1/greeting/Cargo.toml"
	printf 'pub fn text() -> &'"'"'static str {\n    "%s"\n}\n' "$2" >"$1/greeting/src/lib.rs"
	printf 'target/\n' >"$1/.gitignore"
}

real_cargo_run() { # <dir>: cargo run through the wrapper, output in $case_dir/out
	run_in "$1" env PATH="$plugin_bin:$original_path" TARGET_POOL_SIZE=1 cargo run -q --offline || return 1
	expect_status 0 "cargo run in $1"
}

test_real_cargo_hand_off_rebuilds_members() {
	local real
	real=$(PATH=$original_path command -v cargo) || {
		printf '    skipped: cargo is not installed\n'
		return 0
	}
	[ -n "$real" ] || return 0
	local base=$case_dir/ws
	mkdir -p "$base/main"
	write_two_crate_workspace "$base/main" "from main"
	(
		cd "$base/main" &&
			git -c init.defaultBranch=main init -q &&
			git add -A && git commit -q -m init &&
			git worktree add -q -b branch-b ../b
	) || fail "couldn't create the workspace repo" || return 1
	printf 'pub fn text() -> &'"'"'static str {\n    "from b"\n}\n' >"$base/b/greeting/src/lib.rs"
	touch -t 200001010000 "$base/b/greeting/src/lib.rs" "$base/b/app/src/main.rs"

	printf 'pub fn text() -> &'"'"'static str {\n    "from main, edited"\n}\n' >"$base/main/greeting/src/lib.rs"
	real_cargo_run "$base/main" || return 1
	expect_eq "from main, edited" "$(cat "$case_dir/out")" "main's output" || return 1
	real_cargo_run "$base/b" || return 1
	expect_eq "from b" "$(cat "$case_dir/out")" "b's output after the hand-off" || return 1
	real_cargo_run "$base/main" || return 1
	expect_eq "from main, edited" "$(cat "$case_dir/out")" "main's output after handing back"
}

# --- runner ---------------------------------------------------------------------------------

failures=0
case_number=0

run_case() { # <test function> [label]
	case_number=$((case_number + 1))
	case_dir=$tmp_root/case-$case_number
	mkdir -p "$case_dir"
	export STUB_LOG=$case_dir/stub.log
	if ("$1"); then
		printf 'ok   %s%s\n' "$1" "${2:+ [$2]}"
	else
		printf 'FAIL %s%s\n' "$1" "${2:+ [$2]}"
		failures=$((failures + 1))
	fi
}

for test_name in test_lease_and_release test_pass_through_when_target_dir_set \
	test_pass_through_non_build_and_outside_repo test_global_options_before_subcommand \
	test_explicit_target_dir test_nested_cargo_inherits_lease test_finds_real_cargo \
	test_exit_status_passthrough test_settings_validation test_pool_creation_failure \
	test_status_outside_repo test_hand_off_clears_member_fingerprints test_signal_forwarding \
	test_terminal_runs_in_foreground test_real_cargo_hand_off_rebuilds_members; do
	run_case "$test_name"
done

if [ -n "${TARGET_POOL_LOCK_IMPL:-}" ]; then
	lock_impls=$TARGET_POOL_LOCK_IMPL
elif command -v flock >/dev/null 2>&1; then
	lock_impls="flock mkdir"
else
	lock_impls='mkdir'
fi
for impl in $lock_impls; do
	for test_name in test_concurrent_runs_get_different_dirs test_waits_when_all_busy test_affinity \
		test_size_cap test_background_process_does_not_keep_lease; do
		TARGET_POOL_LOCK_IMPL=$impl run_case "$test_name" "$impl"
	done
done
run_case test_stale_mkdir_lock_recovery mkdir
if command -v flock >/dev/null 2>&1; then
	run_case test_mechanisms_agree
fi

if [ "$failures" -gt 0 ]; then
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'all tests passed\n'
