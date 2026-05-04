// Package buildinfo carries values stamped into the binary at link time
// via rules_go `x_defs` in cmd/BUILD.bazel. The values come from
// `tools/workspace_status.sh` (run by `bazel build --stamp`).
//
// Defaults are non-empty so the values are always renderable — an
// unstamped `go run`/`go build` shows "unknown" instead of an empty
// string in the brand bar and debug log.
package buildinfo

// Version is the closest release semver tag (e.g. "0.2.1"). Falls back
// to MODULE.bazel's `version` attribute when no tag exists.
var Version = "unknown"

// Commit is the full git SHA at build time. Empty-tree builds and
// non-git checkouts get "unknown".
var Commit = "unknown"

// GitDescribe is the verbose `git describe --tags --always --dirty`
// output — e.g. "0.2.1-8-g8efe9a0" or "0.2.1-8-g8efe9a0-dirty". Useful
// in debug logs for spotting "I shipped from a dirty tree" mistakes.
var GitDescribe = "unknown"
