#!/usr/bin/env bash
#
# Turn this template into a new project.
#
#   ./init.sh my-project
#
# Renames the crate, rewrites the docs, re-initializes git, and installs the
# hooks. Deletes itself when done.
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

die() {
    echo -e "${RED}error: $1${NC}" >&2
    exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PLACEHOLDER_KEBAB="rust-toolkit-template"
PLACEHOLDER_SNAKE="rust_toolkit_template"

[ $# -eq 1 ] || die "usage: ./init.sh <project-name>"
NAME="$1"

# Cargo accepts a narrower set of names than the filesystem does. Reject early
# rather than letting `cargo build` fail after the rename has already happened.
if ! [[ "$NAME" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    die "'$NAME' is not a valid crate name — use lowercase letters, digits, '-' and '_', starting with a letter"
fi

grep -q "$PLACEHOLDER_KEBAB" Cargo.toml \
    || die "this template has already been initialized"

NAME_SNAKE="${NAME//-/_}"

echo "Initializing '$NAME'..."

# Rewrite both spellings: Cargo and the filesystem use kebab-case, Rust paths
# use snake_case, and the two differ whenever the name contains a hyphen.
FILES=$(grep -rl -e "$PLACEHOLDER_KEBAB" -e "$PLACEHOLDER_SNAKE" \
    --exclude-dir=.git --exclude-dir=target --exclude="init.sh" . || true)

for file in $FILES; do
    sed -i.bak \
        -e "s/${PLACEHOLDER_KEBAB}/${NAME}/g" \
        -e "s/${PLACEHOLDER_SNAKE}/${NAME_SNAKE}/g" \
        "$file"
    rm -f "$file.bak"
    echo "  rewrote $file"
done

# Keep the toolkit's own README as reference, and give the project a fresh one.
mkdir -p docs/decisions
if [ -f README.md ]; then
    mv README.md docs/toolkit.md
fi

cat >README.md <<EOF
# $NAME

## Getting started

\`\`\`sh
cargo run
\`\`\`

## Development

\`\`\`sh
cargo test --quiet                                          # tests
cargo fmt --all                                             # format
cargo clippy --all-targets --all-features -- -D warnings    # lint
cargo deny check                                            # audit dependencies
\`\`\`

With [just](https://github.com/casey/just) installed, \`just ci-local\` runs all four.

Git hooks enforce the same checks on every commit. Install them once with \`./.githooks/install.sh\`.

Conventions this project follows — and the reasoning behind them — are in [CLAUDE.md](CLAUDE.md) and [docs/toolkit.md](docs/toolkit.md).
EOF

cat >docs/decisions/README.md <<'EOF'
# Architectural Decision Records

One file per non-obvious decision, named `NNNN-short-title.md`.

Each record covers: the context that forced a choice, the decision, the alternatives considered and why they lost, and the consequences accepted. An ADR should be readable in under 60 seconds.

Write one when a decision would make future-you ask "why on earth is it like this" — choosing one tool or approach over another, picking a topology or data model, deciding what to expose versus keep internal, or deciding to skip something. Don't write one for obvious choices.
EOF

echo "Verifying the scaffold builds..."
cargo fmt --all
cargo build --quiet || die "the renamed scaffold does not build"

# Fresh history — the template's commits belong to the template.
rm -rf .git
git init -q -b main
git add -A
git commit -qm "chore: initial commit from rust toolkit template"

# Hooks go in AFTER the first commit, deliberately. They guard future work, not
# the freshly-generated scaffold — installing them first means the initial
# commit has to pass a full clippy+test run against code nobody has written yet.
./.githooks/install.sh >/dev/null
echo "  installed git hooks"

rm -f "$ROOT/init.sh"

echo -e "${GREEN}Done.${NC} '$NAME' is ready."
echo
echo "Next:"
echo "  - cargo deny check         (needs: cargo install cargo-deny)"
echo "  - git remote add origin <url> && git push -u origin main"
if ! command -v cargo-deny >/dev/null 2>&1; then
    echo -e "${YELLOW}  note: cargo-deny is not installed; the hook will skip the audit until it is.${NC}"
fi
