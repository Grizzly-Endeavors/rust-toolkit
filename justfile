set shell := ["bash", "-cu"]

# Every recipe here is also documented in README.md as the raw cargo command,
# so `just` is convenience, not required. Nothing in CI depends on it.

default: ci-local

# Run the binary. Args after `--` go to the program: `just run --help`
run *args:
    cargo run -- {{ args }}

test:
    cargo test --quiet

fmt:
    cargo fmt --all

fmt-check:
    cargo fmt --all -- --check

lint:
    cargo clippy --all-targets --all-features -- -D warnings

deny:
    cargo deny check

# The full local gate. Run this before pushing.
ci-local: fmt-check lint test deny

# Install the git hooks (once per clone, and once per new worktree is harmless).
hooks:
    ./.githooks/install.sh

# Update local main from origin without leaving the current branch.
sync:
    git fetch --prune origin
    current=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current" = "main" ]; then \
        git pull --ff-only origin main; \
    else \
        git fetch origin main:main; \
    fi

# Merge the current branch into main, push main, and delete the branch.
merge:
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" = "main" ]; then echo "already on main"; exit 1; fi
    git switch main
    git pull --ff-only origin main
    git merge --no-ff "$branch"
    git push origin main
    git branch -d "$branch"
    if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then \
        git push origin --delete "$branch"; \
    fi

# Stage all changes, commit with MSG, and push the current branch.
ship msg:
    git add -A
    git commit -m "{{ msg }}"
    git push -u origin HEAD
