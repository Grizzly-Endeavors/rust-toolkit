---
name: cargo-workspace-split
description: Plan and carry out splitting a single-crate (or lightly split) Rust project into a Cargo workspace of layered crates so incremental builds, clippy and tests rebuild less. Use when asked to split a crate, extract modules into crates, convert an existing crate into a Cargo workspace or restructure one, design a crate graph or layering, speed up slow incremental cargo check, clippy or test rebuilds by restructuring code, or select tests and lints by the packages a change touches.
---

# Splitting a Cargo project into a workspace

A crate is Cargo's unit of rebuild. Editing any file rebuilds its whole crate and every crate that depends on it, and crates with no dependency path between them compile in parallel. A split pays off when the code that changes often sits in crates few others depend on, and the code many crates depend on rarely changes. Every decision below follows from that.

Work in this order, committing after each step:

1. Measure the baseline (see "Measure before and after").
2. Map the module graph and choose the layers.
3. Turn the root manifest into a workspace with shared lints and dependencies.
4. Extract one crate at a time, lowest layer first, behind a root facade; fix imports; build and test.
5. Verify dependency direction and that each crate compiles alone.
6. Add shared test helpers, cross-crate test placement and change-based test selection as the split needs them.
7. Measure again with the same scenarios and report the comparison.
8. Retire the facade, and the migration list if you made one, when nothing still moves.

The layer plan is an architecture decision: present it to the user (layers, what goes in each, the expected rebuild win, the scenarios that may get slower) before moving code.

## When not to split

Check these first and report them instead of splitting when they hold:

- A clean build and an edit-rebuild are already short (rule of thumb: well under a minute for the edit loop). The split adds manifests, visibility churn and test plumbing for little gain.
- `cargo build --timings` shows most time in third-party crates or in linking. Splitting your own code does not shrink either; fewer test binaries or a faster linker helps more.
- The modules form one tightly coupled cycle that a split would only push into `pub` APIs. Untangle the cycle first; if it will not untangle, the seam is not real.
- Typical changes touch nearly every module anyway, so every crate rebuilds on most edits.

## Choosing layers

Split along the dependency graph and the rebuild fan-out, never by file size. A big module that nothing else imports gains little from becoming a crate; a small type module imported everywhere decides how much rebuilds on every edit.

1. Map module edges. For each top-level module, list the other modules it uses, covering both layouts (`src/<module>.rs` and `src/<module>/`): `grep -rhoE 'crate::(\{ *)?[a-z_]+' src/<module>.rs src/<module>/ 2>/dev/null | sed 's/[{ ]//g' | sort | uniq -c`. Read grouped imports (`use crate::{a::X, b::Y}`) and `super::` reaches out of the module by eye, since the grep sees only the first name in a group. Drop the module's references to itself and record the edges as a table. The build after each move is the final word on edges the grep missed.
2. Find cycles between modules. A cycle cannot cross a crate boundary. Break each one by moving the shared types down into the lower module, or by having the lower module define a trait the higher one implements.
3. Read `cargo build --timings` to see which crates take long and what blocks parallelism: open the HTML report at the path cargo prints after "Timing report saved to".
4. Assign layers:
   - **Low**: code many modules import and that changes rarely: shared types, error types, configuration, utilities, wire and protocol types. Keep heavy third-party dependencies out of the lowest layer, or every crate waits for them.
   - **Middle**: self-contained subsystems that depend only on low layers: storage, a network client, a parser, a file-format codec. Put a subsystem with a heavy dependency (a database driver, a large proc macro) in its own crate so crates that don't need it don't wait on it.
   - **High**: code that changes often and wires things together: the application's orchestration, the binary, the HTTP or CLI surface. Few or no crates depend on it, so editing it rebuilds little.
5. Prefer a wide, shallow graph over a deep chain. Crates on a chain compile one after another; siblings compile in parallel.
6. Weigh generic code: generic functions are compiled in the crate that instantiates them, so moving heavily generic code down saves less than its size suggests.

Signs of a bad seam: many `pub(crate)` items that would have to become `pub` to cross it, or two candidate crates that each need the other. Move the boundary rather than widening visibility across it.

## Workspace manifest

Keeping the existing package at the root, with members under `crates/<dir>/` named `<project>-<dir>`, leaves every existing path, the binary's location and the root sources' `git log` unchanged, so it suits an incremental split. A virtual workspace (a root manifest with only `[workspace]`, every package under `crates/`) fits a split that moves the whole crate in one step, or a root that should hold no code. The examples below use the first layout, where the root manifest is both the workspace and the root package:

```toml
[package]
name = "myproj"
version = "0.1.0"
edition.workspace = true
publish.workspace = true

[dependencies]
myproj-config.workspace = true

[workspace]
members = ["crates/*"]
# Without this, cargo build/test/clippy in the root act on the root package only.
default-members = [".", "crates/*"]
resolver = "3"

[workspace.package]
edition = "<the root package's current edition>"
publish = false

[workspace.dependencies]
anyhow = "<current version>"
tracing = "<current version>"
serde = "<current version>"
myproj-config = { path = "crates/config" }

[workspace.lints.rust]
unsafe_code = "deny"

[workspace.lints.clippy]
# Illustrative entries only; the real table is whatever the project already uses.
pedantic = { level = "warn", priority = -1 }
unwrap_used = "deny"
# ...move the whole existing [lints.*] table here unchanged

[lints]
workspace = true
```

A member manifest:

```toml
[package]
name = "myproj-config"
version = "0.1.0"
edition.workspace = true
publish.workspace = true

[dependencies]
anyhow.workspace = true
serde = { workspace = true, features = ["derive"] } # features add to the workspace entry

[lints]
workspace = true
```

- Move the lint table verbatim. Keep lint changes out of the split, so each move stays a mechanical diff; make any lint change in a separate commit.
- Every member carries `[lints] workspace = true`. A member without it compiles with no project lints and nothing reports it, so add a check that fails on a member manifest missing it (a test or hook that reads each `crates/*/Cargo.toml`).
- Declare every third-party version once in `[workspace.dependencies]` and every internal crate there by path, so members never repeat a version or a path.
- `clippy.toml`, `rustfmt.toml` and `deny.toml` at the workspace root apply to every member; don't copy them into members.

## Moving code behind a facade

Extract lowest layer first: a low crate depends on nothing inside the root, so it can move without dragging anything with it.

1. `mkdir -p crates/<dir> && git mv src/<module> crates/<dir>/src` (keeps history), add the member manifest, make the module root (`mod.rs` or `<module>.rs`) the crate's `src/lib.rs`, and add the crate to the root's `[dependencies]`.
2. Move the third-party dependencies the code uses into the member's `[dependencies]`, and drop any the root no longer uses. Move each Cargo feature that gates the moved code into the member and forward it from the root (`x = ["myproj-config/x"]`) so the root's feature names keep working.
3. Replace the `mod <module>;` line in the root's crate root (`src/lib.rs`, or `src/main.rs` for a binary-only crate) with a facade line, at the visibility the module had, so every existing root path keeps resolving:
   ```rust
   pub(crate) use myproj_config as config; // crate::config::Settings still resolves
   ```
4. Fix imports inside the moved crate: `crate::<own module>::` becomes `crate::`, and `crate::<other module>::` becomes the other member's crate name (`myproj_config::Config`). Member crates cannot use the facade, because they cannot depend on the root.
5. Move inherent `impl` blocks for moved types, and impls of foreign traits for them, out of root modules into the member; the root can no longer write them (inherent impls must live in the type's crate, and the orphan rule blocks foreign-trait impls for a foreign type).
6. Widen visibility only where a real consumer crosses the new boundary. Each `pub(crate)` → `pub` is new API; many of them means the seam is wrong.
7. Grep for strings and values that change with the move: tracing and `RUST_LOG` filters (a member's log target is `myproj_config::…`, not `myproj::config::…`), test filters in scripts and docs, `module_path!()` uses, `include_str!`/`include_bytes!` paths, `env!("CARGO_PKG_*")` and `CARGO_MANIFEST_DIR` (in a member they name the member, so a moved version string reports the member's version), and anything the root `build.rs` generates or sets with `cargo:rustc-env` for the moved code (move that part of the build script with the code, or pass the value in from the root).
8. Build, run the moved crate's tests and the root's tests, commit. Then move the next crate.

The facade keeps the diff of each move small. Retire it once the moves are done: rewrite root call sites to the member crate names in one mechanical sweep and delete the alias. Keep it instead when the root is a published library whose users import those paths; then the facade is the public API and stays documented as such.

## Dependency direction

Rules:

- Members depend only on members in lower layers.
- No member depends on the root package, including as a dev-dependency.
- No cycles. Cargo rejects normal dependency cycles itself, but it accepts a cycle through a dev-dependency, which compiles a second copy of a crate into the tests and produces "expected type `Foo`, found type `Foo`" errors.

Enforce these with a check that runs after every move and in a hook or CI. Record each package's layer (higher number = higher layer, the root highest) and fail on any edge whose target is not in a strictly lower layer, which also catches any edge to the root, and on any package without a layer:

```sh
layers='{"myproj-config":0,"myproj-storage":1,"myproj":9}'
meta=$(cargo metadata --format-version 1 --no-deps) || { echo "layer check: cargo metadata failed" >&2; exit 1; }
bad=$(printf '%s' "$meta" | jq -r --argjson L "$layers" '
  .packages[] | .name as $p
  | if $L[$p] == null then "\($p) has no layer"
    else .dependencies[] | select($L[.name] != null and $L[.name] >= $L[$p])
      | "\($p) -> \(.name) (\(.kind // "normal"))"
    end') || { echo "layer check: jq failed (is jq installed, and is the layers JSON valid?)" >&2; exit 1; }
[ -z "$bad" ] || { printf 'layer violations:\n%s\n' "$bad"; exit 1; }
```

## Each crate compiles alone

When several packages build in one command, Cargo unifies their features. A crate that uses a feature only another crate turns on, or that calls a test helper another crate's dev-dependency enables, compiles in `cargo build --workspace` and fails for anyone who depends on it alone. Check every member on its own, once without dev-dependencies and once with all targets:

```sh
meta=$(cargo metadata --format-version 1 --no-deps) || { echo "isolation check: cargo metadata failed" >&2; exit 1; }
pkgs=$(printf '%s' "$meta" | jq -r '.packages[].name') || { echo "isolation check: jq failed" >&2; exit 1; }
[ -n "$pkgs" ] || { echo "isolation check: cargo metadata listed no packages" >&2; exit 1; }
status=0
for p in $pkgs; do
  cargo check --quiet -p "$p" || { echo "FAILED alone: $p"; status=1; }
  cargo check --quiet -p "$p" --all-targets || { echo "FAILED alone with tests: $p"; status=1; }
done
exit "$status"
```

`cargo check -p <crate>` without `--all-targets` builds the library and binaries only, so dev-dependency features stay off and production code that uses a `test-support` item fails here. Run this check in CI on every change that touches manifests or moves code.

## Shared test helpers: the `test-support` feature

A crate's `#[cfg(test)]` code is invisible to other crates' tests, because a dependency is never compiled with `cfg(test)`. Put helpers other crates' tests need in the lowest crate that can hold them, behind a feature:

```toml
# crates/config/Cargo.toml
[features]
test-support = []
```

```rust
// crates/config/src/lib.rs
#[cfg(any(test, feature = "test-support"))]
pub mod testing;
```

```toml
# a consumer's Cargo.toml: only ever from dev-dependencies
[dev-dependencies]
myproj-config = { workspace = true, features = ["test-support"] }
```

- Turn the feature on only from `[dev-dependencies]`. Enabling it from `[dependencies]` ships test helpers in production builds; the isolation check above catches production code that relies on it.
- Any build with the feature on compiles the helpers as production code: `cargo clippy --all-features`, and also `--all-targets` over the workspace, where a consumer's dev-dependency turns the feature on for the library build. Clippy's test exemptions (`allow-unwrap-in-tests` and friends) apply only inside `#[cfg(test)]` and `#[test]` items, not `cfg(any(test, feature = "..."))`, so a helper that unwraps fails the lint gate. Return `Result` from helpers where it reads well; otherwise put a scoped `#[expect(clippy::unwrap_used, reason = "test-support helper: <why a panic is the right failure here>")]` on the item. Every build that compiles the helper fulfills that expectation. Run `cargo clippy --all-targets --all-features -- -D warnings` after adding a helper to confirm.

## Where tests go after the split

- Unit tests move with their code into the member crate.
- A test that exercises one member and crates below it becomes that member's unit test.
- A test that needs crates from several layers goes in the top crate's integration tests. Use one integration test binary (`tests/it/main.rs` with a `mod` per area) rather than many `tests/*.rs` files: each file is a separate binary that links the package and all its dependencies, so link time multiplies with the file count.
- Give each integration test module a line naming the packages it covers (for example `//! covers: myproj-config, myproj-storage`) so test selection can pick it.
- Test name filters change: a member's test paths start at its own crate root, so a root filter such as `cargo test config::` no longer matches them. Use `cargo test -p myproj-config <filter>`.

## Selecting checks by the packages a change touches

Make hooks and CI check what a change can break, not the whole workspace on every push:

- **Lint/check**: the packages the changed paths belong to, plus every package that depends on them (an API change can break a dependent's build).
- **Tests**: the changed packages' own tests, plus the integration test modules whose covers line names one of them. Run the full suite in CI before merge as the backstop for behavior changes in dependents.
- **Whole workspace**: any change to the root `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, lint or deny configuration, or `.cargo/`.

Map paths to packages with the longest matching member directory, and find dependents with `cargo tree` (bash, including the 3.2 that macOS ships; needs `jq`):

```bash
set -o pipefail
# Empty members means the lookup failed: select the whole workspace.
members=$(cargo metadata --format-version 1 --no-deps | jq -r '.workspace_root as $r
  | .packages[]
  | "\(.manifest_path | rtrimstr("Cargo.toml") | ltrimstr($r + "/"))\t\(.name)"') || members=
[ -n "$members" ] || echo "selection: could not read workspace members; checking the whole workspace" >&2
pkg_for_path() {  # the root package's dir is empty, so it matches whatever no member claims
  printf '%s\n' "$members" | awk -F'\t' -v p="$1" 'substr(p, 1, length($1)) == $1 && length($1) >= best { best = length($1); name = $2 } END { print name }'
}
dependents_of() {  # the package itself and every workspace package that depends on it; non-zero exit when cargo tree fails
  cargo tree --workspace -i "$1" -e normal,build,dev --prefix none --format '{p}' | awk '{print $1}' | sort -u
}
```

Put this in one script that both the hook and CI call, so they never disagree, and have the script print what it selected. When `members` is empty, `dependents_of` exits non-zero, or the script fails in any other way, fall back to the whole workspace and print that it did. Give the script its own test against a small scratch workspace. Files a crate reads from outside its own directory (an `include_str!` of a shared asset, a test fixture read by path) map to the wrong package; keep them inside the crate, or list them in the script with the package they belong to.

## Tracking paths still moving

When one module's move spans several commits or PRs (for example, the module is too large or too entangled to move in one step), part of its code stays in the root while the rest is in the member, and the selection above classifies the leftover as the root package. Only in that case, keep one list file, read by the selection script, hooks and CI, that maps paths still in flight to the package they are moving to:

```text
# path prefix              destination package
src/storage/               myproj-storage
```

The script checks this list before the directory lookup and selects both the root and the destination package for those paths. Remove each line when its code has moved, and delete the lookup once the list stays empty.

## Measure before and after

A split is justified by numbers from the same scenarios on the same machine, so take the baseline before changing anything.

- Create a baseline worktree at the pre-split commit (`git worktree add ../baseline <commit>`).
- Give each side its own explicit target dir for every timed run, from the root of that side's worktree: `CARGO_TARGET_DIR="$PWD/target/measure" cargo …`. Without it, the `cargo` wrapper in this plugin leases dirs from a pool shared by every worktree of the repo, and a hand-off between the two sides or the pool's size cap rebuilds or empties a dir between runs. An explicit `CARGO_TARGET_DIR` makes the wrapper run cargo unchanged. Check that `CARGO_BUILD_BUILD_DIR` is unset and that neither `.cargo/config.toml` nor `~/.cargo/config.toml` sets `build.build-dir`: a build dir outside `target/measure` survives the emptying between clean runs, and a fixed one is shared by both sides. `--timings` reports then land in `target/measure/cargo-timings/` of each worktree; cargo prints the exact path after "Timing report saved to".
- Measure on an idle machine: no other builds, no other agent sessions compiling (`target-pool status` shows no leases). Use the same toolchain on both sides. If `CARGO_MAKEFLAGS` names a build jobserver, prefix the timed commands with `env -u CARGO_MAKEFLAGS` so they do not wait on other sessions' tokens.
- Disable sccache or any other compiler-caching wrapper for the runs (`RUSTC_WRAPPER=` before `cargo`). Repeated clean builds into the same target dir path hit the entries the earlier runs left, which hides the compile cost the split is meant to change.
- Run the clean build two or three times, emptying the side's target dir before each run (`rm -rf target/measure`), with no warm-up. Run every other scenario once to warm up, then at least five times. Report the median and the spread of each; a noisy scenario needs more runs, not a single good number.
- For an edit scenario, make a real edit that changes compiled code (for example, change a string literal in a function body) and alternate between two versions so every run rebuilds. Make the same logical edit on both sides: the same function in the same file, wherever it lives now.

Scenarios, each timed for `cargo clippy --all-targets` (or `cargo check`) and for `cargo test --no-run` (the build part of testing):

| Scenario | What it shows |
|---|---|
| No-op rebuild | Fingerprinting overhead; a regression means a build script reruns every time |
| Edit a middle crate only the top crate depends on | The best case the split creates |
| Edit a low crate (many dependents) | The split's cost; expect this to stay close to baseline |
| Edit the top crate | The common edit loop for application code |
| Clean build | Whether the split slowed full builds (more crates, more linking) |

A benchmark runner makes the loop easy, for example, from the root of each worktree: `hyperfine --warmup 1 --runs 5 --prepare '<script that flips the edit>' 'env -u CARGO_MAKEFLAGS CARGO_TARGET_DIR="$PWD/target/measure" RUSTC_WRAPPER= cargo clippy --all-targets'` (hyperfine runs the command through a shell, so `$PWD` expands there to the worktree). Report a table of baseline and split medians per scenario, name any scenario that got slower and why, and include the commit of each side.
