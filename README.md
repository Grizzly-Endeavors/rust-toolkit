# Rust toolkit

An opinionated starting point for a Rust project built with AI coding agents. It is the distilled version of the setup behind a dozen or so working Rust repos — the lint block, the hooks, the test layout, and the agent instructions that go with them.

The point isn't the config files. It's that the config files and the agent instructions say the same thing, so the rules an agent is told to follow are the rules the build actually enforces.

## Use it

```sh
git clone <this-repo> my-project
cd my-project
./init.sh my-project
```

`init.sh` renames the crate, writes a fresh README, re-initializes git with a clean history, installs the hooks, and deletes itself. You get a project that builds and passes its own gate on the first commit.

## What you need

- **Rust** (stable — `rust-toolchain.toml` pins the channel and pulls `rustfmt` + `clippy`)
- **[cargo-deny](https://github.com/EmbarkStudios/cargo-deny)** — `cargo install cargo-deny`. The hook skips the audit if it's missing rather than failing, but you want it.
- **[just](https://github.com/casey/just)** — optional. Every recipe is also a plain cargo command; the README of a generated project lists both forms.

That's the whole tool list. There is no test-runner replacement, no coverage tooling, no `cargo-machete`. If something isn't here, it's because it wasn't earning its keep.

## What's in the box

| File | What it does |
| --- | --- |
| `Cargo.toml` | The lint block — ~45 clippy denies, with the reasoning inline |
| `clippy.toml` | Test-code exemptions for unwrap/expect/panic/dbg |
| `rustfmt.toml` | 100-col, edition 2024, Unix newlines |
| `deny.toml` | Vulnerability and supply-chain gating |
| `rust-toolchain.toml` | Pins the channel and required components |
| `justfile` | `fmt` / `lint` / `test` / `deny` / `ci-local` plus git flow helpers |
| `.githooks/` | pre-commit and commit-msg, with a worktree-safe installer |
| `CLAUDE.md` | The agent instructions — the same rules, in prose |
| `src/` | A working skeleton that demonstrates four of the conventions |

The `src/` tree is small on purpose but not empty: `main.rs` is the thin-shell pattern, `lib.rs` is where logic goes, `config.rs` is a pure module with a sibling test file, and its env handling shows the Rust 2024 workaround. Delete it once you've read it.

## The opinions

**The lints are strict because agents take every shortcut that isn't explicitly denied.** Warnings get ignored; only hard errors change behavior. A human developer brings judgment about when `.unwrap()` is fine — an agent brings whatever gets the build green. The strictness is a substitute for that judgment. This is the single load-bearing idea in the whole toolkit; the rest follows from it.

**`#[expect]`, never `#[allow]`.** Both suppress a lint. Only `#[expect]` warns when the suppression becomes unnecessary, which means suppressions get cleaned up instead of accumulating. `allow_attributes` and `allow_attributes_without_reason` are denied, and the pre-commit hook rejects any staged `#[allow(`, so there are two independent gates on this.

**`unsafe_code = "deny"`, not `forbid`.** `forbid` can't be overridden at the item level, so one legitimate FFI shim becomes a reason to weaken the config for the whole crate. `deny` lets a genuine boundary carry a scoped `#[expect(unsafe_code, reason = "...")]` while everything else stays closed.

**`pedantic` sits at `warn`, not `deny`.** New clippy releases add lints to that group. At `deny`, a toolchain upgrade breaks the build with no code change. At `warn` plus `-D warnings` on the command line, you still can't merge past them — but you can bump the toolchain, see what's new, and fix it, rather than being unable to build at all.

**`anyhow` at boundaries, `thiserror` at the domain.** `anyhow::Result` inside binaries and at subsystem edges, with `.context()` chained at each layer so a log shows the causal chain. `thiserror` enums for errors a caller actually matches on or maps to an HTTP status or exit code. `anyhow` wraps `thiserror`, not the reverse. Add `thiserror` when you have a type that earns it — the template doesn't ship with it.

**Unit tests live in a sibling file, not at the bottom of the impl.** `src/config.rs` declares `#[cfg(test)] #[path = "tests/config.rs"] mod tests;` and the tests live in `src/tests/config.rs`. The `#[path]` attribute makes the test file a *child* of the impl module, so `use super::*` still reaches private items — you lose nothing. What you gain is that a three-line edit doesn't drag four hundred lines of test noise through the context window on every read. This is the most unusual convention here and the one that pays off most on a mature module.

**Logic goes in pure modules; IO and frameworks stay in a thin shell.** HTTP handlers, event loops, and GUI callbacks call into modules that do the actual work and can be tested without a runtime. `main.rs` only initializes tracing, dispatches, and maps a `Result` to an exit code — the `exit` lint is denied everywhere else specifically to keep it that way.

**`deny.toml` blocks on vulnerabilities, not on abandonment.** `unmaintained = "none"` and `yanked = "warn"` are deliberate. A transitive crate whose maintainer walked away carries a RUSTSEC advisory with no upgrade path — you can't fix it without forking whichever framework pulls it in, so blocking on it just makes the repo undeployable over something you have no lever on. Vulnerabilities are actionable; abandonment usually isn't. Supply-chain *source* gating (`wildcards`, `unknown-registry`, `unknown-git`) stays strict, because those you control.

**Every failure must be visible.** Silent failures — swallowed errors, `let _ = result`, `.map_err(|_| ...)`, retries that hide the underlying problem — are the thing the whole config is built to prevent. `map_err_ignore` and `let_underscore_must_use` are denied for exactly this reason.

## Things that will bite you

**Don't put `#[expect(clippy::unwrap_used, ...)]` in a test file.** `clippy.toml` already exempts unwrap in tests, so the expectation never fires — and an unfulfilled `#[expect]` is itself a hard error under `-D warnings`. This is the most common way to break the config, and the error message doesn't point at the cause.

**Integration tests in `tests/` do need a header.** `tests_outside_test_module` is denied project-wide and fires on top-level `#[test]` functions, which is exactly what an integration test is. Unlike `unwrap_used` it can't be exempted from `clippy.toml`, so every file in `tests/` starts with:

```rust
#![expect(
    clippy::tests_outside_test_module,
    reason = "integration tests live at crate root by cargo convention"
)]
```

**Don't call `std::env::set_var` in tests.** Rust 2024 made it `unsafe`. Write env-reading functions as a pair instead — a zero-arg function that reads the real environment, and a `_from_env` sibling taking a lookup closure the test supplies. `src/config.rs` implements this.

**Workspace lint inheritance is all-or-nothing.** If you split into a workspace and one crate needs to relax a single lint, Cargo will not let it inherit `[workspace.lints]` and override that one lint. It has to reproduce the entire block locally. This bites hardest with macro-heavy frameworks, where a derive generates code that trips a lint you can't reach with an item-level `#[expect]` because the offending code originates inside the macro. There's no clean fix — just know the duplication is Cargo's constraint, not sloppiness, and leave a comment in both files saying they must stay in sync.

**Verify a version before you pin it.** Not from memory, not from an example, not from an old config — from `cargo search` or the releases page, at the moment you pin. A stale pin fails in ways that look like real bugs, so the debugging happens before the cause is even suspected. Check the project is still alive, too: pinning the newest release of an abandoned crate is worse than an old pin, because it invites building on something that will force a migration later.

## What's deliberately absent

No `[profile]` block — release tuning is project-specific and a template that guesses at it is just noise to delete. No `cargo-nextest`; plain `cargo test --quiet` has been enough. No coverage tooling or thresholds — the lints enforce that failures are visible, which is a different and more useful property than a coverage number. No `.cargo/config.toml`. No `rust-version` / MSRV pin, since these are binaries rather than published libraries; add one if you publish.

Start single-crate. Split into a workspace when a genuine second binary or shared library shows up, not before — and read the lint-inheritance note above first.

## Making it yours

Everything here is a starting point you own after cloning, not a dependency. Drift is expected. The two pieces worth keeping in sync if you change them are `Cargo.toml`'s lint block and the "Lint Configuration" section of `CLAUDE.md` — if those disagree, the agent is being told one thing while the build enforces another, and that's worse than either rule alone.
