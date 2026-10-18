# rust-build

A Claude Code plugin for Rust repositories that agents build in parallel git worktrees. It keeps a small pool of warm Cargo target directories per repository and leases one to each build-type cargo run, so a fresh worktree does not start with an empty `target/` and pay a full cold build.

## Why

Each `git worktree add` starts with no build output. Without help, every new worktree compiles its whole dependency graph from scratch, and every agent session that builds in a new worktree repeats that cost. The pool replaces that per-worktree cost with a shared set of target directories that stay warm across runs. A worktree that builds again gets the directory it used last, so its incremental state is still there.

## How it works

### The `cargo` wrapper

While the plugin is enabled, Claude Code puts the plugin's `bin/` directory on the `PATH` of the Bash tool. A SessionStart hook moves it to the front, so `cargo` resolves to the wrapper, `bin/cargo`. The wrapper finds the real `cargo` further down `PATH` and decides what to do with each invocation:

- Build-type subcommands (`build`, `check`, `clippy`, `test`, `run`, `doc`, `bench`, `rustc`, `rustdoc`, `fix`, `nextest`, and the aliases `b`, `c`, `t`, `r`, `d`) are run through `target-pool run`, which leases a target directory.
- Everything else (`fmt`, `add`, `update`, `tree`, `metadata` and so on) runs the real cargo directly, with no lease.
- Leading `+toolchain` arguments and cargo's global options (`-v`, `-q`, `--color`, `--frozen`, `--locked`, `--offline`, `--config`, `-Z`, `-C`) are skipped when the wrapper looks for the subcommand.

The wrapper passes straight through to the real cargo, without leasing, when any of these hold:

- `CARGO_TARGET_DIR` is already set. Nested cargo calls, such as a build script or a test that runs cargo, inherit the outer lease this way.
- `--target-dir` is passed explicitly.
- The current directory is not inside a git repository.
- `TARGET_POOL_DISABLE=1` is set.

### The pool

The pool lives under the main checkout's `target/pool/`, as `target/pool/0` through `target/pool/N-1`. The main checkout is found from any worktree through `git rev-parse --git-common-dir`, so every worktree of a repository shares one pool. Lock files and bookkeeping live beside the directories under `target/pool/` as well, never inside a directory's build output. `cargo clean` in the main checkout, or deleting the repository, removes the pool.

Each run does the following:

1. Takes a lease on a free directory. A worktree that used a directory last gets that same directory again, so its build stays warm. Otherwise any free directory is taken, preferring one that no other worktree claims as its last.
2. If every directory is leased, prints one line on stderr saying it is waiting for a free build directory, and blocks until one frees. A run never falls back to a cold or shared directory.
3. Runs the command with `CARGO_TARGET_DIR` set to the leased directory.
4. Checks the directory's size once the command finishes. If it exceeds the cap, the directory is emptied while the lease is still held, and one line on stderr reports the size and the cap.
5. Releases the lease and exits with the command's exit status.

The lease is held by the `target-pool` process, not by the command it runs, and the lock file descriptor is closed in the child. A child process that starts a long-lived daemon therefore does not keep the lease. SIGINT, SIGTERM, SIGHUP and SIGQUIT received by `target-pool` are forwarded to the child, so an interrupted build stops and the lease is released.

### SessionStart hooks

The plugin registers two SessionStart hooks.

- `hooks/session-path` appends `bin/` to the front of `PATH` by writing an `export` line to `$CLAUDE_ENV_FILE`. It does nothing when that variable is unset. Because the wrapper skips its own copy, a directory that appears twice on `PATH` is harmless.
- `hooks/prune-worktree-targets` removes the `target/` directory of an idle agent worktree. A worktree under `<main checkout>/.claude/worktrees/` is idle when none of its files outside `target/` and `.git` has changed for `TARGET_POOL_PRUNE_HOURS` hours. The hook never touches the pool, never follows a symlink, and never deletes anything outside a worktree's own `target/`. It prints one line when it removes something, and it always exits 0, so it cannot fail a session.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `TARGET_POOL_SIZE` | `4` | Number of directories in the pool. Concurrent build-type cargo runs beyond this count wait for a free one. |
| `TARGET_POOL_CAP_GB` | `40` | Size in GB above which a leased directory is emptied after a run. |
| `TARGET_POOL_DISABLE` | unset | Set to `1` to make the wrapper and `target-pool run` plain pass-throughs. |
| `TARGET_POOL_PRUNE_HOURS` | `24` | Hours without file changes before the SessionStart hook removes an idle worktree's `target/`. |

## The `target-pool` script

`bin/target-pool` is standalone. It does not depend on Claude Code or on the rest of the plugin, and the wrapper calls it for every leased run. It has three subcommands.

- `target-pool run [--] <command> [args...]` leases a directory, runs the command with `CARGO_TARGET_DIR` set to it, and exits with the command's status. If `CARGO_TARGET_DIR` is already set, or the current directory is not in a git repository, the command runs unchanged.
- `target-pool status` prints each pool directory with its index, its size, whether it is leased and by which PID, and the worktree that used it last. Run it when a build is waiting, to see who holds the directories.
- `target-pool path` prints the pool root for the current repository, for scripts and documentation.

Errors name what went wrong and what to do about it. If the pool cannot be created, the script says why and exits non-zero. It does not quietly run cold.

The script runs on Linux and macOS. It uses `flock` when that command is available. Otherwise it falls back to an atomic `mkdir` lock that records the owner's PID and recovers a lock whose owner is gone. Both mechanisms agree on the same on-disk layout, so two copies of the script on one machine use the same pool without stepping on each other.

## Using the script in a repository without the plugin

A repository can use the lease script from its own git hooks or scripts without installing the plugin. Copy `bin/target-pool` into the repository, for example to `scripts/target-pool`, and call it there:

```sh
scripts/target-pool run -- cargo test --quiet
```

Copies of the script interoperate, because the lock protocol and the directory layout are the same in every copy. Update a vendored copy by copying the file again from the plugin.

## Installing

The plugin is in the `plugin/` directory of the rust-toolkit repository, `https://github.com/Grizzly-Endeavors/rust-toolkit`. Claude Code installs plugins from a marketplace, which is a repository or file that lists them. Add a marketplace that lists this plugin with a `git-subdir` source, then install from it:

```json
{
  "name": "example-marketplace",
  "owner": { "name": "Example Owner" },
  "plugins": [
    {
      "name": "rust-build",
      "source": {
        "source": "git-subdir",
        "url": "https://github.com/Grizzly-Endeavors/rust-toolkit.git",
        "path": "plugin"
      }
    }
  ]
}
```

```text
/plugin marketplace add <owner>/<marketplace-repo>
/plugin install rust-build@example-marketplace
```

The plugin has no user configuration. Its version is set in `.claude-plugin/plugin.json`, so an installed copy changes only when that version changes.

Claude Code does not install a plugin that has a `bin/` directory on claude.ai or Cowork. Use it from the Claude Code CLI or the desktop app.

The plugin does not install a Cargo jobserver or a compiler cache. Those are machine-level settings, and the `rust-build-speed` skill describes them.

## Skills

- `cargo-workspace-split` covers when and how to split a single-crate Rust project into a workspace, so that agent builds touch less code.
- `rust-build-speed` covers the build-speed settings that sit outside the plugin, such as a compiler cache and a machine-wide build jobserver.
