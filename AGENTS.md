# AGENTS.md | rust-toolkit-template

Project-specific guidance for agents working in this repository. Universal rules live in `~/Projects/AGENTS.md`.

## Build & Quality Gates

```sh
cargo run                                    # run the binary
cargo test --quiet                           # always --quiet; never plain cargo test
cargo fmt --all                              # format
cargo fmt --all -- --check                   # verify formatting
cargo clippy --all-targets --all-features -- -D warnings
cargo deny check                             # advisories, licenses, sources
```

The `justfile` wraps these: `just test`, `just lint`, `just deny`, `just ci-local` (the full gate). Every recipe is also a plain cargo command — `just` is convenience, not required.

**Pre-commit hooks** run fmt (auto-applied and re-staged) → clippy → tests → `cargo deny` if installed, then reject staged `dbg!()` and `#[allow(`. Install once with `./.githooks/install.sh` or `just hooks`. **Bypassing with `--no-verify` is forbidden.** If a hook fails, fix the underlying issue.

**Parallel worktrees:** agent sessions that build in several git worktrees of the same repository should enable the `rust-build` Claude Code plugin from `https://github.com/Grizzly-Endeavors/rust-toolkit` (its `plugin/` directory). It leases warm Cargo target directories from a per-repository pool, so a new worktree does not start with a cold build. Projects generated from this template do not contain the plugin's files; install it from that repository.

## Lint Configuration

Clippy is configured with strict denies — not warnings. The lint block in `Cargo.toml` is intentional and not to be relaxed without explicit approval.

### What's denied and why

- **`unwrap_used`, `expect_used`, `panic`, `get_unwrap`**: no panics on untrusted input or error paths. Use `?`, `anyhow::Context`, or explicit handling.
- **`todo`, `unimplemented`, `dbg_macro`**: no incomplete or debug code ships.
- **`exit`**: only `main.rs` may call `std::process::exit`. Library code returns `Result`.
- **`indexing_slicing`, `string_slice`**: use `.get()` / slice-returning methods that produce `Option`.
- **`map_err_ignore`, `let_underscore_must_use`**: no silent error swallowing.
- **`error_impl_error`**: don't name a domain error type `Error`. It collides with every other crate's and reads as "the" error type.
- **`missing_errors_doc`, `missing_panics_doc`, `must_use_candidate`**: public API must document its failure modes and must-use returns.
- **`allow_attributes`, `allow_attributes_without_reason`**: every suppression uses `#[expect(..., reason = "...")]`, never `#[allow(...)]`. `#[expect]` warns when the suppression goes stale; `#[allow]` sits there forever.
- **`tests_outside_test_module`**: tests live in `#[cfg(test)]` modules. Integration tests in `tests/` need the file-level escape below.
- **`too_many_lines`**: keep functions short.
- **`wildcard_enum_match_arm`, `shadow_unrelated`**: no lazy match catch-alls, no surprise variable shadowing.
- **`rc_buffer`, `rc_mutex`**: antipatterns.
- **`clone_on_ref_ptr`, `format_push_string`, `redundant_type_annotations`**: code quality.

### Relaxed

- `pedantic` is at `warn` with `priority = -1`: pedantic baseline, but `deny` would break builds on toolchain upgrades that add new lints. Note that `-D warnings` in the lint command still makes them blocking — the level exists so a toolchain bump is a fixable failure, not a broken build.
- `module_name_repetitions = "allow"`: pervasive pattern in this codebase style.

### Unsafe

`unsafe_code = "deny"` (not `forbid`) — `deny` allows a scoped `#[expect(unsafe_code, reason = "FFI boundary")]` at the item level when genuinely needed. `forbid` can't be overridden item-level, which turns one legitimate FFI shim into a reason to weaken the whole config.

### Test modules

Test code may freely use `.unwrap()`, `.expect()`, `panic!`, and `dbg!` — the root `clippy.toml` exempts all four in tests.

**Do not add `#[expect(clippy::unwrap_used, ...)]` to test files.** The lint is already exempt, so the expectation never fires and becomes an unfulfilled-expectation hard error under `-D warnings`. This is the single most common way to break this config.

`tests_outside_test_module` is *not* test-exempt — see the integration-test boilerplate below.

## Async

- **Tokio is the default runtime.** `#[tokio::main]` in `main.rs`, `tokio::spawn` for background tasks, `tokio::select!` for concurrent I/O supervision.
- **Async-first**: use async for I/O; fall back to sync only for CPU-bound or genuinely trivial operations.
- **No blocking calls inside async functions.** Use `tokio::fs`, `tokio::process`, etc. If a blocking call is unavoidable, wrap it in `spawn_blocking`.
- **Shared state**: wrap in `Arc<T>` with thread-safe interior mutability (`DashMap`, `Mutex`/`RwLock` when contention is low, channels for message passing).
- **Graceful shutdown**: listen for `SIGINT`/`SIGTERM` via `tokio::signal`; let the `tokio::select!` in the main loop fall out on signal and drain in-flight work.
- **Tracing init happens before anything else async starts.**

## Error Handling

- **`anyhow::Result<T>`** at subsystem boundaries and inside binaries. Chain context with `.context("failed to load user settings")` so logs show the causal chain.
- **`thiserror` enums** for domain errors that callers match against or that need to map to specific outcomes (HTTP status codes, exit codes, user-facing error kinds). Add `thiserror` when you have such a type — not before.
- **`anyhow` wraps `thiserror`**: domain errors bubble up as typed errors; boundaries widen them to `anyhow::Error` with added context.
- **`main.rs` is the only place that maps `Result` to exit code.** Every other function returns `Result`; the `exit` lint is denied elsewhere.
- **No `.unwrap()` / `.expect()` outside of tests.** If you genuinely know a value is present, use `.expect("reason — invariant explanation")` inside a scoped `#[expect(clippy::expect_used, reason = "...")]` with a real reason.
- **No silent error swallowing.** `let _ = ...` on a `Result` is denied; so is `.map_err(|_| ...)`. Every error either propagates or gets logged with context before being handled.

## Module Layout

- **`mod.rs`** primarily contains declarations and curated `pub use` re-exports. Module-level coordination logic is fine when it belongs there; gratuitous plumbing is not.
- **Group related types in one file** (e.g. `Message`, `Role`, `ToolCall` together in `llm/types.rs`) rather than one-type-per-file.
- **Shell vs core split**: IO-bound and framework-bound code (HTTP handlers, event loops, GUI callbacks) lives in a thin *shell* layer that calls into *pure* modules where all the logic is. The shell is usually not unit-tested; the pure modules are. If you find yourself adding logic to a shell module, move it into a pure module first and let the shell call the validated result.
- **Binary vs library**: even binary crates keep a thin `main.rs` that delegates to a library module — this makes the logic testable and keeps `main.rs` at the "init tracing → dispatch → exit code" skeleton.
- **Boundaries at the domain's joints.** Modules should divide where the problem divides, so a change to one concern touches one place. A boundary drawn because a file got long produces a `utils.rs` grab-bag; a boundary drawn at a real seam produces modules you can reason about alone.

## Test Organization (Rust)

### Unit test file layout

Unit tests do **not** live at the bottom of the impl file. They live in a sibling `tests/` subdirectory, loaded via a `#[path]` module declaration at the bottom of the impl file. This keeps impl files short and prevents a three-line edit from dragging hundreds of lines of test noise into the context window.

- `src/foo.rs` → tests at `src/tests/foo.rs`
- `src/foo/bar.rs` → tests at `src/foo/tests/bar.rs`
- `src/foo/mod.rs` → tests at `src/foo/tests/foo.rs` (named after the module, not `mod.rs`)

Declared at the bottom of the impl file as:

```rust
#[cfg(test)]
#[path = "tests/foo.rs"]
mod tests;
```

The `#[path]` attribute makes the loaded file a **child** of the impl module, so `use super::*;` retains full access to private items — no visibility inflation.

See `src/config.rs` and `src/tests/config.rs` for a worked example.

### Integration test boilerplate

Every `tests/*.rs` file at crate root must start with:

```rust
#![expect(
    clippy::tests_outside_test_module,
    reason = "integration tests live at crate root by cargo convention"
)]
```

This is required because `clippy::tests_outside_test_module` is denied project-wide and fires on top-level `#[test]` functions — which are exactly what integration tests are. Unlike `unwrap_used`, it is not controllable from `clippy.toml`, so it still needs the per-file `#[expect]`.

### What gets tested

- **Pure modules** (parsing, validation, state transitions, path manipulation, error construction): every pure module ships with tests on the day it lands.
- **Shell modules** (HTTP handlers, framework integrations, event loops): usually not unit-tested. Exercised via integration tests or manual verification.

### Env var handling in tests

Rust 2024 made `std::env::set_var` / `remove_var` `unsafe`. **Do not use them in tests.** Instead, structure env-reading functions as a dual pair:

- A public zero-arg function that reads the real process env (e.g. `Settings::from_process_env()`).
- A public `_from_env` sibling taking an `EnvLookup<'_>` closure (e.g. `Settings::from_env(get)`).

The zero-arg function calls the sibling with `&|k| std::env::var_os(k)`. Tests construct closures with fixed keys. `src/config.rs` implements this pattern.

### Rationale

This layout is optimized for LLM agent workflows where the default "read the whole file" cost is multiplied by every edit. Sibling test files preserve Rust's native test ergonomics (private access, `cargo test` runs them automatically) while dramatically cutting read-time noise on mature modules.
