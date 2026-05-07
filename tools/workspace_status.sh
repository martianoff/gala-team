#!/usr/bin/env bash
# Bazel workspace_status_command — writes key/value pairs to stable-status.txt
# (cached across builds) and volatile-status.txt (always re-evaluated). The
# `STABLE_*` keys are read by `x_defs` in cmd/BUILD.bazel and linked into
# app/buildinfo at build time. Keep STABLE_* lines deterministic w.r.t. the
# git tree so unrelated rebuilds reuse the linked binary.
#
# Triggered by `build --stamp` + `build --workspace_status_command=...` in
# .bazelrc. Runs from the repo root.
set -u

# Robust against detached HEAD / shallow clones / non-git checkouts.
git_or() {
    local out
    if out=$(git "$@" 2>/dev/null); then
        echo "$out"
    else
        echo "unknown"
    fi
}

# Module version from MODULE.bazel — pessimistic fallback when no tags exist.
mod_version=$(grep -E '^[[:space:]]*version[[:space:]]*=' MODULE.bazel 2>/dev/null \
    | head -1 \
    | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$mod_version" ]; then
    mod_version="0.0.0"
fi

git_commit=$(git_or rev-parse HEAD)
git_tag=$(git_or describe --tags --always --dirty)

# Closest semver tag for the brand bar — strip the `-N-gSHA` distance
# suffix that `git describe` appends when HEAD is past the tag, and the
# `-dirty` suffix when the tree has uncommitted changes. Falls back to
# MODULE.bazel only when no tag exists at all.
nearest_tag=$(git_or describe --tags --abbrev=0)
if echo "$nearest_tag" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    version="$nearest_tag"
else
    version="$mod_version"
fi

echo "STABLE_GIT_COMMIT $git_commit"
echo "STABLE_GIT_TAG $git_tag"
echo "STABLE_GALA_TEAM_VERSION $version"
