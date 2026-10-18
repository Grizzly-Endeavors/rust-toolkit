---
name: rust-build-speed
description: Audit and improve Rust build speed and build disk usage, especially where many agent sessions or git worktrees build the same repo at once. Use when cargo builds, tests or clippy feel slow, compile times or link times are long, a no-op build still rebuilds, a fresh worktree rebuilds everything, target/ dirs are huge or fill the disk, build disk writes or SSD wear are a concern, builds wait on a file lock, the machine is overloaded by parallel builds, or when setting up or debugging sccache, a shared target dir, a target-dir pool, debug-info settings, duplicate dependency versions, default features, the linker, or a build jobserver.
---

# Rust build speed audit

Run the audit below in order. Each step names what to check, the command, and how to decide. Measure before you change anything and after each change you keep; a build-setting change without a measured win on a named scenario is reverted. A guard that is not meant to change build time, such as the duplicate-version check in step 6.3, stays without a timing.

## 1. Measure a baseline

Every later decision compares against these numbers, so take them carefully.

1. **Make the machine idle.** Check `uptime` (load average well under the core count from `nproc`, or `sysctl -n hw.ncpu` on macOS), `pgrep -fl 'cargo|rustc'` (no other builds), and `target-pool status` (no leases held by other sessions). If other sessions are building, wait or say in your report that the numbers are noisy.
2. **Control the caches.** Time with an explicit target dir so you know what is warm: `CARGO_TARGET_DIR=<dir>` bypasses the pool. For a cold build use a fresh empty dir and `RUSTC_WRAPPER=` (empty) to keep sccache out. If a build jobserver is configured, run the timing with `env -u CARGO_MAKEFLAGS` so the build is not waiting on other sessions' tokens.
3. **Time named scenarios** and report the median and spread of each. Run the cold build 2 or 3 times, emptying the dir before each run, with no warm-up; run every other scenario once to warm up, then at least 5 times.
   - **cold**: empty target dir, full `cargo build` (or the command agents run most, such as `cargo clippy --all-targets` or `cargo test --no-run`).
   - **no-op**: the same command again with nothing changed. Anything above a second or two means something is rebuilding every time (step 8).
   - **leaf edit**: a one-line change inside a function body of the top crate (the binary or the crate nothing depends on), then rebuild.
   - **low edit**: the same in a crate most of the workspace depends on, then rebuild.
   Make the edit differ on every run, for example by toggling a line between two versions; `touch` alone undersells the cost because rustc's incremental cache sees identical content. `hyperfine --prepare '<toggle edit>' '<build command>'` automates this if it is installed.
4. **See where the time goes:** `cargo build --timings` writes an HTML report and prints "Timing report saved to <path>"; open that path, since under the pool the target dir is a pool dir. Look for long single crates on the critical path, a long tail of one crate building alone, proc-macro and build-script crates that gate everything after them, and link time of the final binaries and test binaries.
5. **Disk writes** (when disk is the concern): on Linux, `/usr/bin/time -v cargo build` reports "File system outputs" in 512-byte blocks; on macOS, `/usr/bin/time -l` reports block output operations. `du -sk <target dir>` before and after gives growth.

To compare a change, keep a baseline worktree at the old commit (`git worktree add <dir> <old-commit>`), give each side its own explicit target dir (for example `CARGO_TARGET_DIR="$PWD/target/measure"` run from inside each worktree, so pool hand-offs and the size cap cannot touch them), warm both the same way, and alternate runs between the two so drift in machine load hits both.

## 2. Warm target dirs for worktrees

A new git worktree has an empty `target/`, so its first build is a full cold build even though another worktree of the same repo built the same dependencies minutes ago. With many sessions each in its own worktree, cold builds dominate.

This plugin's `cargo` wrapper leases a warm target dir from a per-repo pool for each build-type cargo run (`build`, `check`, `clippy`, `test`, `run`, `doc`, `bench`, `rustc`, `rustdoc`, `fix`, their aliases, and `nextest`).

- **Check it is active:** `command -v cargo` resolves to the plugin's `bin/cargo` in the Claude Code Bash tool while the plugin is enabled. Other shells (a human terminal, CI) call the real cargo.
- **Check nothing overrides it:** `grep -n 'target-dir\|build-dir' .cargo/config.toml ~/.cargo/config.toml` and `env | grep -E 'CARGO_TARGET_DIR|CARGO_BUILD_'`. An explicit `CARGO_TARGET_DIR`, `--target-dir` or `CARGO_BUILD_BUILD_DIR` skips the pool. The pool's `CARGO_TARGET_DIR` takes precedence over a configured `build.target-dir`. A `build.build-dir` set in cargo config moves intermediate artifacts out of the pool dirs: a fixed path brings back the shared-dir problems below, and a per-workspace template (such as one using `{workspace-path-hash}`) loses the pool's warm dirs. Remove it so intermediates stay in the leased dir.
- **See it:** `target-pool status` lists each pool dir with its size, whether it is leased and by which PID, and the worktree that used it last. `target-pool path` prints the pool root, which is `target/pool/` inside the repo's main checkout.
- **How it picks:** a run gets the dir its worktree used last if that one is free, otherwise a free dir no other worktree claims, otherwise any free dir. When a dir passes to a different worktree, the pool deletes the incoming worktree's workspace members' fingerprints in it, so those members rebuild while dependencies stay warm (the freshness trap below is why). When every dir is leased it prints one line saying it is waiting and blocks until one frees; it never falls back to a cold or shared dir.
- **Size it:** `TARGET_POOL_SIZE` (default 4) sets the number of dirs; `TARGET_POOL_CAP_GB` (default 40) caps one dir, which is emptied after a run that leaves it over the cap, with one line on stderr saying so. Set them in the environment every session inherits (the Claude Code settings `env` block or the shell profile).
- **Decide:** if sessions often print the waiting line, or `target-pool status` shows every dir leased, raise `TARGET_POOL_SIZE` toward the number of sessions that build at once. If disk is tight, lower the size or the cap. If dirs hit the cap often, cut their size (steps 5 and 9) before raising the cap.
- **Idle worktrees:** a worktree's own `target/` (left by builds outside the pool) under `<main checkout>/.claude/worktrees/` is deleted by the plugin's session-start hook once none of the worktree's files outside `target/` and `.git` have changed for `TARGET_POOL_PRUNE_HOURS` hours (default 24). The pool is never pruned. Lower the hours if those dirs fill the disk.
- **Opt out:** `TARGET_POOL_DISABLE=1` makes the wrapper a plain pass-through.
- `cargo clean` in the main checkout deletes the pool along with everything else in its `target/`.

**Do not point every worktree at one shared target dir** (a global `CARGO_TARGET_DIR` or `build.target-dir`). It looks like the simple version of the pool and is worse:

- Cargo locks the build directory for the whole build, so every session's build waits for the one in progress ("Blocking waiting for file lock on build directory"). Parallel sessions become serial.
- It is unsafe as well as slow. Workspace crates get the same artifact names and fingerprints in every worktree, and cargo decides freshness by comparing the building worktree's source mtimes with the last build's outputs. So worktree B can see worktree A's build of a crate as `Fresh` and silently run A's code; tests then pass or fail against the wrong branch. When cargo does notice, each switch rebuilds the crates you edit most. Registry dependencies share fine.

**Check a dir that changed worktrees** (a seeded dir, step 10, a dir shared outside the pool, or any time results look like another branch's code): run `CARGO_TARGET_DIR=<dir> cargo build -v 2>&1 | grep -E '^ +(Fresh|Dirty|Compiling)'` (the explicit dir bypasses the pool, so the check reads that dir) and confirm the workspace crates that differ between the two worktrees are not `Fresh`. If they are, rebuild them in that dir with `CARGO_TARGET_DIR=<dir> cargo clean -p <member>` for each such member; dependencies stay warm.

## 3. Parallel sessions: a build jobserver

Each cargo defaults to one job per CPU. N sessions building at once start N times that many rustc processes, oversubscribing CPU and RAM (linking is RAM-heavy, and running out of memory kills builds or swaps the machine). Every build gets slower, and the total gets slower too.

A build jobserver caps the total: a shared pool of job tokens using the GNU make jobserver protocol, which cargo honours when `CARGO_MAKEFLAGS` (or `MAKEFLAGS`) names a jobserver, taking a token per rustc it starts instead of using its own `-j`. Build scripts that use the jobserver (such as C builds through the `cc` crate) share the same tokens.

**Check:** `echo "$CARGO_MAKEFLAGS"` in the shell agents use. If many sessions build at once on the machine and it is empty, recommend a jobserver to the user; it is machine setup, not a project change.

**Setting one up on a machine**, in outline:

1. A long-running process (a user service, so it starts at login and restarts on failure) creates a FIFO, writes N one-byte tokens into it, and keeps the FIFO open for as long as it runs: a FIFO's buffered data is discarded when its last open handle closes, so without a holder the tokens vanish between builds. N is about the core count.
2. Every shell that runs cargo exports `CARGO_MAKEFLAGS="-j --jobserver-auth=fifo:/path/to/fifo"`. Put the export where non-interactive shells read it too, since agent tools usually run commands in non-interactive shells.
3. Each client also runs one job on an implicit token it never reads from the FIFO, so K concurrent builds can run N + K jobs. Lower N slightly if that matters.
4. A client killed mid-build never returns the tokens it held. Have the holder process refill the FIFO back to N when no builds are running, or the pool shrinks over time.
5. **Verify:** start two large builds (or clippy runs) at once and watch `pgrep -x 'rustc|clippy-driver' | wc -l`; it should stay near N + 2, not twice the core count. If it does not, the cargo in use may be too old for `fifo:` auth and is ignoring the variable.

**Limits:** it caps the jobs cargo starts. rustc also takes tokens for its extra codegen threads when it inherits the jobserver, but under sccache rustc runs inside the sccache server, which uses its own jobserver, so those threads escape the machine-wide cap. Tools that do not speak the protocol (npm, docker, a separate make without the flags) are not capped. With a jobserver in the environment, `cargo build -j` and `CARGO_BUILD_JOBS` do not raise the cap. A build may sit idle waiting for tokens while other sessions compile; that is the cap working, not a hang. `env -u CARGO_MAKEFLAGS <cmd>` bypasses it for one command.

## 4. sccache

sccache wraps rustc and caches each crate's compiled output, keyed by a hash of the compiler, the source files, the command-line flags, the working directory and part of the environment (see the limits below). Under the pool each pool dir mostly hits only its own earlier entries, so sccache's main win is outside the pool: CI and work on a single checkout.

**Check:** `grep -n rustc-wrapper ~/.cargo/config.toml .cargo/config.toml` and `echo "$RUSTC_WRAPPER"`. `sccache --show-stats` shows hits, misses and the reasons for non-cacheable calls.

**Enable:**

```toml
# ~/.cargo/config.toml (per machine, not committed to the project)
[build]
rustc-wrapper = "sccache"
```

Set the cache size with `SCCACHE_CACHE_SIZE` (for example `"50G"`); the default is small when several target dirs each keep their own entries. The sccache server reads `SCCACHE_*` variables when it starts, so run `sccache --stop-server` after changing them.

**Limits to know before expecting a win:**

- It does not cache incrementally compiled crates. In dev builds cargo compiles workspace members incrementally, so your own crates always miss; only dependencies hit. `CARGO_INCREMENTAL=0` makes them cacheable but gives up incremental rebuilds, which usually costs more on edit-rebuild loops than it saves.
- It does not cache crates that invoke the linker (binaries, `cdylib`/`dylib`, proc-macros) and does nothing for linking itself, so link-bound builds see no gain.
- The key includes every `CARGO_*` variable in rustc's environment (except a few such as `CARGO_MAKEFLAGS`), plus any variable a crate reads with `env!`, so builds that differ in such a value miss each other's entries. `CARGO_TARGET_DIR` is one of them, and the pool sets it to the leased dir, which is why two pool dirs miss each other; a crate that includes generated code from `OUT_DIR` misses across target dirs for the same reason.
- The key also includes the working directory and source paths, so a crate built from a different checkout path misses. Registry dependencies compile from the same path for every worktree; workspace crates do not. Check whether your sccache version's base-directory setting (`SCCACHE_BASEDIRS`) applies to Rust compiles before counting on it.
- So under the pool, sccache hits only when a pool dir recompiles something it built before at the same path and has since lost: refilling the dir after the size cap or `cargo clean` empties it, including the dependency builds for every lockfile and feature set that dir had compiled. A pool dir filled for the first time, or a fresh clone's pool, misses. For warm starts in new worktrees, the pool's warm dirs (incremental state and fingerprints that already match) do far more than sccache.

**Decide:** if `--show-stats` shows a low hit rate after several builds, find the reason it lists before tuning anything else.

## 5. Debug info in the dev profile

Debug info is often the largest share of codegen time, link time, and target dir size. The dev default is full debug info for every crate.

**Check:** `[profile.dev]` and `[profile.test]` in the workspace root `Cargo.toml`, then ask whether anyone steps through this project in a debugger. Apply one of the two options.

**Nobody uses a debugger:** keep line tables only. Panic backtraces and profilers keep file and line; debuggers lose variables and types.

```toml
[profile.dev]
debug = "line-tables-only"
```

`debug = 0` (`false`) also drops line numbers from backtraces; use it for CI or one-shot builds.

**Someone uses a debugger:** keep full debug info for workspace crates and drop it for dependencies, which almost nobody steps into.

```toml
[profile.dev.package."*"]    # every non-member package
debug = false
```

**Either way, on Linux:** `split-debuginfo = "unpacked"` under `[profile.dev]` writes debug info to `.dwo` files beside the objects, so the linker copies less (macOS already defaults to it). Check that `gdb`/`lldb` still find symbols after the change.

Re-measure cold and leaf-edit builds and target dir size.

## 6. Duplicate dependency versions

Two semver-incompatible versions of one crate (for example `0.7` and `0.8`) both compile, and so does everything under each.

**Find:** `cargo tree -d --target all` lists crates present in more than one version, including those pulled in only by build or dev dependencies (they still compile under `cargo test` and `clippy --all-targets`). `cargo tree -i <crate>@<version> --target all` shows the inverted tree for one version, ending at the workspace member or direct dependency that brings it.

**Drop**, in order of preference:

1. Move the direct dependency that pulls the old version to a release that uses the new one: `cargo update -p <direct-dep>@<version>` for a semver-compatible release, or a version bump in `Cargo.toml` (check the latest release first).
2. Align versions across the workspace with `[workspace.dependencies]` and `<crate>.workspace = true` in each member, so members cannot drift apart.
3. Guard it: `cargo deny check bans` with `multiple-versions = "warn"` (or `"deny"`) under `[bans]` in `deny.toml`, and list each tolerated duplicate under `skip` as `{ crate = "<crate>@<version>", reason = "<why>" }`.

**Tolerate a duplicate** when the old version comes from a dependency with no release that moves forward, when both copies are small (check their build time in `--timings`), or when removing it means forking a crate. Spend effort on duplicates of heavy crates (async runtimes, HTTP stacks, `syn`, serialization frameworks), not on small leaf crates.

## 7. Default features

Default features often pull in heavy optional dependencies (TLS backends, compression, full runtimes) a project never uses.

**Find:** `cargo tree -e features -i <heavy-crate>` shows which feature of which dependency enables the heavy crate. Pick candidates from the longest crates in `--timings`.

**Trim:**

```toml
[dependencies]
some-crate = { version = "x.y", default-features = false, features = ["the-one-you-use"] }
```

Then build, run the tests, and re-run `cargo tree -e features -i <heavy-crate>`: features unify, so another dependency that enables the same feature keeps the heavy crate in the build, and the trim saves nothing until that one is trimmed too.

Each distinct feature set of a shared dependency is a separate build, kept side by side in the target dir. `cargo build -p <member>` and a whole-workspace `cargo build` can select different feature sets, so alternating them costs one extra build of the affected dependencies per target dir (per pool dir) plus the disk for it. Prefer one command shape for routine builds.

## 8. Rebuild churn

If the no-op scenario is not near-instant, or a leaf edit rebuilds far more than the leaf, find out why before tuning anything else.

- `cargo build -v 2>&1 | grep -E '^ +Dirty'` names each crate that rebuilt and the reason (for example "the file `src/lib.rs` has changed").
- A build script without `cargo:rerun-if-changed` lines reruns whenever any file in its package changes, and everything after it rebuilds. Add `rerun-if-changed` for the files it actually reads.
- Each distinct combination of `RUSTFLAGS`, features and profile gets its own artifacts, so a new combination costs a full build of what it affects once per target dir, and the disk to keep it. Put flags agents use in `.cargo/config.toml` rather than ad hoc in the environment, so every session uses the same combination.

## 9. Other levers

Each is worth a look when `--timings` points at it.

- **Linker:** link time of large binaries and many test binaries. Rust 1.90 and later link with `lld` by default on `x86_64-unknown-linux-gnu`; other targets may still use the system linker. `mold` can be faster: `[target.<triple>] linker = "clang"` and `rustflags = ["-C", "link-arg=-fuse-ld=mold"]` in `.cargo/config.toml`. Confirm which linker ran with `readelf -p .comment <binary> | grep -iE 'mold|lld'`. Keep linker choices in per-machine config unless every contributor has the linker.
- **Test binaries:** every file in `tests/` is its own binary to link. Folding integration tests into one binary (one `tests/<name>/main.rs` that declares the other files as modules) cuts link time and disk.
- **`incremental`:** on by default in dev for workspace members. It speeds edit-rebuild loops and costs disk (incremental dirs are a large share of target size and writes). Turn it off (`CARGO_INCREMENTAL=0`) for CI and one-shot builds, keep it for iteration.
- **`codegen-units`:** if `[profile.dev]` or `[profile.test]` sets a low value (often copied from a release profile), remove it; the dev default is already tuned for build speed.
- **`opt-level` for dependencies in dev:** `[profile.dev.package."*"] opt-level = 2` makes cold builds slower and tests that do heavy computation much faster. Worth it when tests are runtime-bound and target dirs stay warm.
- **Proc macros:** derive-heavy crates and `syn` sit early on the critical path. Look for proc macros you can drop or features of them you can trim (step 7).
- **Big crates:** one crate that builds alone for a long stretch at the end of `--timings` is a candidate for splitting; see the `cargo-workspace-split` skill.
- **Inside one crate:** `cargo +nightly rustc -- -Z self-profile` records where one crate's compile time goes; read the output with the `summarize` tool from the `measureme` project.

## 10. Cutting build disk writes

Most writes come from debug info (step 5), incremental dirs (step 9), and every cold build of a fresh target dir (step 2). After those, copy-on-write helps when you seed a target dir from a warm one.

On a filesystem with reflinks, a copy shares the original's blocks until either side changes them, so cloning a large warm target dir takes little time and almost no new writes. Btrfs, XFS (formatted with reflink support), bcachefs, ZFS with block cloning enabled, and APFS on macOS support it; ext4 does not. Check the filesystem with `df -T <dir>` (Linux) or `diskutil info <mount point>` (macOS) before suggesting it.

Clone with `cp -a --reflink=always <src> <dst>` on Linux, which fails instead of silently making a full copy where reflinks are unsupported, or `cp -cRp <src> <dst>` on macOS. Preserve modification times either way: cargo's freshness checks depend on them.

This is an option for seeding a dir by hand (for example a new pool dir or a baseline worktree); the pool does not clone dirs itself. A seeded dir holds the source worktree's builds of workspace crates, so run the check from step 2 ("Check a dir that changed worktrees") in the worktree that will use it.

## Report

For each change you made or recommend: the setting, the scenario medians before and after (cold, no-op, leaf edit, low edit), target dir size before and after when relevant, and what the change gives up (debugger detail, incremental rebuilds, runtime speed). Say which items are machine setup for the user (jobserver, sccache, linker, filesystem) rather than project changes.
