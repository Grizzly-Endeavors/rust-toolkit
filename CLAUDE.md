# CLAUDE.md | rust-toolkit-template

This file provides guidance to Claude Code when working with code in this repository.

## How to Operate

### Agent discipline

The strict lint config, pre-commit hooks, and `deny`-level rules in this repo are **intentional**, not accidental over-engineering. They exist because AI agents take every shortcut that isn't explicitly denied; warnings get ignored. Treat them as the floor.

- If you see lazy code here, the correct response is to *add* a guardrail that prevents the whole class (a lint, a hook check), not to fix the single instance and move on.
- **Do not relax lint rules, disable hooks, or bypass checks** without explicit approval from the user. Ever.
- If a rule is genuinely wrong for a specific case, use a scoped `#[expect(..., reason = "...")]` with a real reason — never a blanket `#[allow]`.

### Current state only

Code comments, docstrings, and all documentation must describe the system **as it is right now**. No "used to be X", no "this replaces the old Y", no "temporary until Z", no "new in v2", no migration narration, no dated status blurbs. Transient state goes stale silently and then actively misleads the next reader — human or agent.

- Don't leave a tombstone comment where something was deleted — delete it; git has the history.
- If a comment explains *why* the code is shaped a certain way and that reason is still live, it stays — that's current state, not history. If the reason is "because we migrated from X", it belongs in an ADR under `docs/decisions/`, not inline.
- **`TODO`/`FIXME` markers in code are not allowed** — not even with an issue reference, since the referenced issue gets closed or reshaped and the marker rots in place. Future work goes in an issue or `TODO.md`; if it's not worth filing, it's not worth a comment.

### Version pinning — verify before you pin

**Always check the current stable version before pinning anything** — crates, container images, CLI tools, toolchains, GitHub Actions. Never carry a version forward from memory, an example, or an old config; look it up from the authoritative source (`cargo search`, `cargo info`, the releases page) at the moment you pin it.

A stale pin fails in ways that look like real bugs, so the debugging time is spent before the cause is even suspected. **Also check the project is still maintained**, not just the latest version number — pinning to the newest release of something abandoned is worse than an outdated pin, because it invites building on a dependency that will force an expensive migration later. If the latest release is years old, the repo is archived, or upstream points to a successor, surface it rather than silently pinning the dead one.

### Sub-agent orchestration

When spawning sub-agents for parallel or delegated work, include this in every agent prompt:

> **Do NOT run tests, linting, or formatting checks.** Do NOT attempt to commit changes. Focus only on implementing the requested changes. Verification will run centrally afterward.

The orchestrating session runs `cargo fmt`, `cargo clippy`, and `cargo test --quiet` after all sub-agent work completes, then commits. This avoids conflicting commits from parallel branches, wasted cycles verifying incomplete work, and agents blocking on failures caused by another agent's in-flight changes.

### Working style

- **Surface design decisions before finalizing.** Don't silently pick between architectural alternatives — present the shape and the tradeoff.
- **Fix unrelated issues when you find them.** Never say "this isn't from my changes" and move on.
- **Don't stop at "the code is written."** Done means implemented, verified, and committed.

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

## Naming

- **Domain-specific names**: prefer descriptive names that match the domain (`send_chat_completion` over generic `run`, `spawn_widget_window` over `handle`).
- **Common abbreviations OK**: `cfg`, `dir`, `msg`, `ctx`, `cmd` are fine; avoid obscure ones.
- **Semantics must match logic**: structs, enums, and functions should make it abundantly clear what they do. If the logic doesn't match the semantics of the name, refactor the logic or rename it — don't let the name lie.

## Error Messages

- **Always include context**: `"failed to parse config at {path}"` — not just `"parse error"`.
- **Lowercase, no trailing period** — Unix style, chains cleanly with context wrappers.
- **User-facing vs developer-facing**: developers get structured, chained context; end users get plain-language, actionable messages. These are different audiences — don't conflate them.

## Comments

- **Explain *why*, never *what***. The code shows what; comments exist for non-obvious reasoning — hidden constraints, subtle invariants, workarounds for specific bugs, behavior that would surprise a reader.
- **No comments that restate the code**: `// increment counter` on `counter += 1` is noise. Delete it.
- **Doc comments**: one-line summary for public items. Expand only when behavior is non-obvious (error modes, performance notes, thread-safety). Don't narrate parameters that are already named.
- **No planning / decision / analysis comments in shipped code.** Those belong in `docs/decisions/`, commit messages, and PR descriptions.

## Visibility

- **Private-first**: start with no visibility modifier. Add `pub` only when there's a consumer that demands it. Prefer `pub(crate)` when the consumer is inside the same crate.
- **Treat public as a commitment**: once something is public, it's API. The cheapest API change is the one you never made public in the first place.

## Testing

**Testing is a first-class operation — NEVER skip test implementation.**

- Every pure module ships with tests on the day it lands. "I'll add tests later" is how untested code accumulates.
- **Always run `cargo test --quiet`**, never plain `cargo test` — `--quiet` suppresses per-test noise and surfaces failures plus the summary.
- Don't test implementation details — test behavior. A refactor that preserves behavior shouldn't break tests.
- The shell (IO, framework, GUI) is usually not unit-tested; it's exercised via integration tests or manual verification. But the *logic* reachable from the public API should be testable without the shell.

## Observability — No Silent Failures

**Every failure must be visible.** This is non-negotiable.

### Developer-facing: rich, structured diagnostics

- Every error path produces a log entry with enough context to diagnose without reproducing.
- Use structured fields — `error!(error = %e, path = %path, "failed to read config")` — not prose string interpolation.
- Chain error context at each layer with `anyhow::Context` so the log shows the full causal chain.
- Pick the right level: `error` (operation failed), `warn` (recoverable/degraded), `info` (major lifecycle event), `debug` (state transitions), `trace` (payloads, per-tick).

### User-facing: clear, actionable messages

- Plain language, no Rust type paths. `eprintln!("{err:#}")`, never `eprintln!("{err:?}")` — the latter shows debug formatting and internal types to someone who can't act on either.

### Avoid log spam

- Do not log every retry individually — log once at `warn` when retries start, and once when they resolve or exhaust.
- Do not log routine successful operations ("heartbeat ok", "connection alive"). Absence of errors is the signal that things work.
- Anything that would fire on every poll tick or event under normal conditions belongs at `trace` at most, never `info`.

## Git Workflow

**Single-branch model**: all work lands on `main`.

1. Create a feature branch from `main` with a prefixed name (`feat/`, `fix/`, `refactor/`, `docs/`, `ci/`, `chore/`).
2. **Commit frequently** — especially during large multi-phase tasks. Pre-commit hooks enforce fmt, lint, and tests.
3. Wrapup: check for anything unfinished, update docs, note breaking changes.
4. Push the branch and merge into `main`.

Rules:

- **Hook bypass (`--no-verify`) is FORBIDDEN.** If a hook fails, fix the underlying issue.
- **First-line commit conventions**: ≤72 chars, lowercase, imperative mood, conventional prefix, no trailing period.
- All changes must be committed before giving the user a completion summary.

## Lint Configuration

Clippy is configured with strict denies — not warnings. The lint block in `Cargo.toml` is intentional and not to be relaxed without explicit approval.

### Why strict

These rules are strict because this project is primarily developed with AI coding agents, and agents will take every shortcut that isn't explicitly denied. Warnings get ignored; only hard errors change behavior. The strictness is a substitute for the discipline a human developer would bring naturally.

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
