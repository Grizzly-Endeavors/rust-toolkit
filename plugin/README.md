# rust-build

A Claude Code plugin for Rust repositories that agents build in parallel git worktrees. It keeps a small pool of warm Cargo target directories per repository and leases one to each build-type cargo run, so a fresh worktree does not start with an empty `target/` and pay a full cold build.

## Why

Each `git worktree add` starts with no build output. Without help, every new worktree compiles its whole dependency graph from scratch, and every agent session that builds in a new worktree repeats that cost. The pool replaces that per-worktree cost with a shared set of target directories that stay warm across runs. A worktree that builds again gets the directory it used last, so its incremental state is still there.

## How it works

### The `cargo` wrapper

While the plugin is enabled, Claude Code puts the plugin's `bin/` directory on the `PATH` of the Bash tool. A SessionStart hook moves it to the front, so `cargo` resolves to the wrapper, `bin/cargo`. The wrapper finds the real `cargo` further down `PATH` and decides what to do with each invocation:

- Build-type subcommands (`build`, `check`, `clippy`, `test`, `run`, `doc`, `bench`, `rustc`, `rustdoc`, `fix`, `nextest`, and the built-in aliases `b`, `c`, `t`, `r`, `d`) are run through `target-pool run`, which leases a target directory.
- Everything else (`fmt`, `add`, `update`, `tree`, `metadata`, `clean` and so on) runs the real cargo directly, with no lease. That includes user-defined `[alias]` entries (an `xtask` alias, for example) and third-party `cargo-*` subcommands other than `nextest`: they run in the worktree's own `target/`.
- Leading `+toolchain` arguments and cargo's global options (`-v`, `-q`, `--color`, `--frozen`, `--locked`, `--offline`, `--config`, `-Z`, `-C`) are skipped when the wrapper looks for the subcommand.

The wrapper passes straight through to the real cargo, without leasing, when any of these hold:

- `CARGO_TARGET_DIR` is already set. Nested cargo calls, such as a build script or a test that runs cargo, inherit the outer lease this way.
- `CARGO_BUILD_TARGET_DIR` or `CARGO_BUILD_BUILD_DIR` is set.
- `--target-dir` is passed explicitly (before any `--`; arguments after `--` belong to the program cargo runs).
- The project is not inside a git repository.
- `TARGET_POOL_DISABLE=1` is set.
- `git` is not installed. This one prints a warning on stderr.

The project is the directory cargo builds in: the current directory, or the directory given with the global `-C <dir>` option, or the directory of the manifest given with `--manifest-path <path>` (relative to the `-C` directory when both are given, as cargo resolves it). The wrapper hands both options to `target-pool run`, so the repository, the pool, the worktree the lease is recorded for, and the workspace whose fingerprints a hand-off clears (see below) all come from that project. A `-C` or manifest directory that does not exist passes straight through, and cargo reports the error.

A target directory set in cargo's configuration files does not opt out. `CARGO_TARGET_DIR` takes precedence over `build.target-dir` in a project's or user's `.cargo/config.toml` and over `--config build.target-dir=…`, so the lease overrides them. Only the environment variables above and `--target-dir` cause a pass-through. A `build.build-dir` in a cargo configuration file is honoured by cargo and moves the intermediate build output, which is where the warm state lives, out of the leased directory, so the pool does little for such a project.

### The pool

The pool lives under the main checkout's `target/pool/`, as `target/pool/0` through `target/pool/N-1`. The main checkout is found from any worktree through `git rev-parse --git-common-dir`, so every worktree of a repository shares one pool. Lock files and bookkeeping live beside the directories in `target/pool/.locks/`, never inside a directory's build output. In a git submodule the pool lives under the superproject's `.git/modules/<name>/target/pool`, and in a bare repository under the repository directory itself; `target-pool path` prints where it is.

Each run does the following:

1. Takes a lease on a free directory. A worktree that used a directory last gets that same directory again, so its build stays warm. Otherwise any free directory is taken, preferring one that no other worktree claims as its last.
2. If every directory is leased, prints one line on stderr saying it is waiting for a free build directory, and blocks until one frees. A run never falls back to a cold or shared directory.
3. If the directory was last used by a different worktree, deletes the fingerprints of the workspace members the command builds before running it. Cargo names and fingerprints members by their path inside the workspace and checks freshness by modification time, so without this a member could count as up to date with the other worktree's code. The members come from `cargo metadata --no-deps` for the project, so they rebuild while dependencies stay warm. When `cargo metadata` fails, every fingerprint in the directory is cleared instead, and a line on stderr says so.
4. Runs the command with `CARGO_TARGET_DIR` set to the leased directory.
5. Checks the directory's size once the command finishes. If it exceeds the cap, the directory is emptied while the lease is still held, and one line on stderr reports the size and the cap.
6. Releases the lease and exits with the command's exit status.

The lease is held by the `target-pool` process, not by the command it runs, and the lock file descriptor is closed in the child. A child process that starts a long-lived daemon therefore does not keep the lease.

### Signals

Without a terminal attached, as in the Bash tool, the command runs in a process group of its own. SIGINT, SIGTERM, SIGHUP and SIGQUIT received by `target-pool` are forwarded to that whole group, so an interrupted build stops, rustc processes included, and the lease is released. The exit status is the command's, or 128 plus the signal number when the command died of a signal.

With a terminal attached to stdin, stdout or stderr, the command runs in the foreground, so it can read the terminal. Ctrl-C and signals sent to the process group work as usual. A signal sent only to the `target-pool` process takes effect once the command exits.

SIGKILL cannot be forwarded. Killing `target-pool` with it releases the lease while the build keeps running, and cargo's own lock on the build directory then makes the next run of that directory wait for the orphaned build instead of building beside it.

### Build outputs

Under a lease, cargo writes binaries and other artifacts to the leased directory, `target/pool/<n>/<profile>/…` in the main checkout, not to the worktree's `target/<profile>/`. A later build from another worktree that leases the same directory overwrites them, and `target-pool clean` or the size cap deletes them. To run a binary, use `cargo run`. For a binary needed at a fixed path, build and copy it within one leased command, for example `target-pool run -- sh -c 'cargo build --release && cp "$CARGO_TARGET_DIR/release/app" dist/'`, or set `CARGO_TARGET_DIR` for that build so it bypasses the pool.

### Cleaning

`target-pool clean` is the safe way to empty the pool while other builds may run. It empties every directory that is free at that moment, holding its lease while it does, keeps the lock and bookkeeping files, names the leased directories it skipped, and exits 0.

`cargo clean` runs the real cargo. In a worktree it deletes that worktree's own `target/`, which leased builds do not use. In the main checkout it deletes the whole pool, lock files included. Do that only when nothing is building: a run that was waiting recreates the lock files and takes a directory at once, so a directory whose build was still running can be granted to a second run. Deleting the repository also removes the pool.

### SessionStart hooks

The plugin registers two SessionStart hooks.

- `hooks/session-path` writes an `export` line to `$CLAUDE_ENV_FILE` that puts `bin/` first on `PATH`. It does nothing when that variable is unset. Because the wrapper skips its own copy, a directory that appears twice on `PATH` is harmless.
- `hooks/prune-worktree-targets` removes the `target/` directory of idle agent worktrees. A worktree under `<main checkout>/.claude/worktrees/` is idle when none of its files outside `target/` and `.git` has changed for `TARGET_POOL_PRUNE_HOURS` hours. It skips the worktree the session runs in, and it deletes a `target/` only when that directory holds the `CACHEDIR.TAG` file cargo writes into every target directory it creates, so a `target/` that git tracks or another tool made is kept. The hook never touches the pool, never follows a symlink, and never deletes anything outside a worktree's own `target/`. It runs in the background and reports through the session's context on the next turn: which worktrees' `target/` it deleted, and any it failed to delete. It always exits 0, so it cannot fail a session.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `TARGET_POOL_SIZE` | `4` | Number of directories in the pool. Concurrent build-type cargo runs beyond this count wait for a free one. |
| `TARGET_POOL_CAP_GB` | `40` | Size in GB above which a leased directory is emptied after a run. Decimals such as `12.5` work, and `0` empties the directory after every run. |
| `TARGET_POOL_DISABLE` | unset | Set to `1` to make the wrapper and `target-pool run` plain pass-throughs. |
| `TARGET_POOL_PRUNE_HOURS` | `24` | Hours without file changes before the SessionStart hook removes an idle worktree's `target/`. |

## The `target-pool` script

`bin/target-pool` is standalone. It does not depend on Claude Code or on the rest of the plugin, and the wrapper calls it for every leased run. It has four subcommands.

- `target-pool run [-C <dir>] [--manifest-path <path>] [--] <command> [args...]` leases a directory, runs the command with `CARGO_TARGET_DIR` set to it, and exits with the command's status. `-C` and `--manifest-path` name the project the command builds, with the same meaning as cargo's options of those names; pass the same values the command gets. The command runs unchanged, without a lease, when `CARGO_TARGET_DIR`, `CARGO_BUILD_TARGET_DIR` or `CARGO_BUILD_BUILD_DIR` is set, when `TARGET_POOL_DISABLE=1` is set, when the project is not in a git repository, or when `git` is not installed (with a warning on stderr).
- `target-pool status` prints each pool directory with its index, its size, whether it is leased and by which PID, and the worktree that used it last. Run it when a build is waiting, to see who holds the directories.
- `target-pool path` prints the pool root for the current repository, for scripts and documentation.
- `target-pool clean` empties every pool directory that is not leased, and names the leased ones it skipped. See "Cleaning" above.

Errors name what went wrong and what to do about it. If the pool cannot be created, the script says why and exits non-zero. It does not quietly run cold.

The script runs on Linux and macOS. It uses `flock` when that command is available. Otherwise it falls back to an atomic `mkdir` lock that records the owner's PID and recovers a lock whose owner is gone. Both mechanisms agree on the same on-disk layout, so two copies of the script on one machine use the same pool without stepping on each other.

## Using the script in a repository without the plugin

A repository can use the lease script from its own git hooks or scripts without installing the plugin. Copy `bin/target-pool` into the repository, for example to `scripts/target-pool`, and call it there:

```sh
scripts/target-pool run -- cargo test --quiet
scripts/target-pool run --manifest-path tools/gen/Cargo.toml -- cargo run --manifest-path tools/gen/Cargo.toml
```

Copies of the script interoperate, because the lock protocol and the directory layout are the same in every copy. Update a vendored copy by copying the file again from the plugin.

## Installing

The plugin is in the `plugin/` directory of the rust-toolkit repository, `https://github.com/Grizzly-Endeavors/rust-toolkit`. Claude Code installs plugins from a marketplace, which is a repository or file that lists them. To install it, add this entry to the `plugins` list of a marketplace you use or maintain. The `git-subdir` source fetches only the `plugin/` directory:

```json
{
  "name": "rust-build",
  "source": {
    "source": "git-subdir",
    "url": "https://github.com/Grizzly-Endeavors/rust-toolkit.git",
    "path": "plugin"
  }
}
```

Then add that marketplace and install the plugin from it:

```text
/plugin marketplace add <marketplace repository or path>
/plugin install rust-build@<marketplace name>
```

To try the plugin without a marketplace, clone the repository and start Claude Code with the plugin loaded for that session only:

```sh
claude --plugin-dir <path to the clone>/plugin
```

The plugin has no user configuration. Its version is set in `.claude-plugin/plugin.json`, so an installed copy changes only when that version changes.

Claude Code does not install a plugin that has a `bin/` directory on claude.ai or Cowork. Use it from the Claude Code CLI or the desktop app.

The plugin does not install a Cargo jobserver or a compiler cache. Those are machine-level settings, and the `rust-build-speed` skill describes them.

## Skills

- `cargo-workspace-split` covers when and how to split a single-crate Rust project into a workspace, so that agent builds touch less code.
- `rust-build-speed` covers the build-speed settings that sit outside the plugin, such as a compiler cache and a machine-wide build jobserver.
