// Debug log infrastructure — Go-side helpers for the gala-side
// debuglog.gala. The pattern mirrors trace.go: gala owns the policy
// (when to log, what shape the records take, env-var name) and Go
// owns the things gala can't express cleanly (bitwise OpenFile flags,
// long-lived file handle cache, RemoveAll).
//
// Single flag, two artifacts:
//   GALA_TEAM_DEBUG=1   →  enables both events.jsonl and per-member
//                          chunk traces. When set, the trace dir
//                          defaults to <repo>/.gala_team/sessions/
//                          debug/traces and events.jsonl lands at
//                          <repo>/.gala_team/sessions/debug/events.jsonl.
//   GALA_TEAM_TRACE_DIR  power-user override for the per-member chunk
//                        trace dir only — if set, events.jsonl is
//                        independent and only emitted when
//                        GALA_TEAM_DEBUG is also on.
//
// SetDebugRepo is called once from main() after the project is
// resolved so subsequent log calls don't have to thread the repo path
// through every dispatch site.

package runtime

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var (
	debugRepoMu sync.RWMutex
	debugRepo   string
)

// SetDebugRepo records the resolved project repo path so DebugDir() and
// AppendDebugEvent() can derive their target paths without callers
// passing the repo on every call. Safe to call multiple times — last
// write wins. Does nothing when given an empty string.
func SetDebugRepo(repo string) {
	if repo == "" {
		return
	}
	debugRepoMu.Lock()
	debugRepo = repo
	debugRepoMu.Unlock()
}

// GetDebugRepo returns the value most recently passed to SetDebugRepo,
// or "" when never set.
func GetDebugRepo() string {
	debugRepoMu.RLock()
	defer debugRepoMu.RUnlock()
	return debugRepo
}

// DebugEnabled reports whether GALA_TEAM_DEBUG is set to a truthy
// value. Only "1", "true", "yes", "on" (case-insensitive) count;
// anything else is treated as off so a stray "GALA_TEAM_DEBUG=0" or
// "GALA_TEAM_DEBUG=false" actually disables the flag.
func DebugEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("GALA_TEAM_DEBUG")))
	switch v {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

// DebugDir returns the canonical debug-log directory for the current
// repo, or "" when no repo has been set yet (very early startup).
// Always under .gala_team/sessions/debug so it lives alongside
// latest.json + events.jsonl + per-member archives.
func DebugDir() string {
	repo := GetDebugRepo()
	if repo == "" {
		return ""
	}
	return filepath.Join(repo, ".gala_team", "sessions", "debug")
}

// EventsPath returns <debug-dir>/events.jsonl, or "" when the debug
// dir is unknown.
func EventsPath() string {
	d := DebugDir()
	if d == "" {
		return ""
	}
	return filepath.Join(d, "events.jsonl")
}

// DefaultTraceDir returns the per-member chunk trace dir derived from
// the debug dir — used when GALA_TEAM_DEBUG=1 but
// GALA_TEAM_TRACE_DIR is not explicitly set. Returns "" when no debug
// repo is registered yet.
func DefaultTraceDir() string {
	d := DebugDir()
	if d == "" {
		return ""
	}
	return filepath.Join(d, "traces")
}

// EffectiveTraceDir centralises the precedence rules for the per-
// member chunk trace dir:
//
//  1. GALA_TEAM_TRACE_DIR — explicit override, always wins
//  2. GALA_TEAM_DEBUG=1   — derived dir under the debug folder
//  3. ""                  — tracing disabled
//
// trace.go's TraceDir() now delegates here so GALA_TEAM_DEBUG=1 alone
// gets full per-chunk traces without an extra env var.
func EffectiveTraceDir() string {
	if v := os.Getenv("GALA_TEAM_TRACE_DIR"); v != "" {
		return v
	}
	if DebugEnabled() {
		return DefaultTraceDir()
	}
	return ""
}

// debugFileMu serialises writes to events.jsonl. The events stream is
// low-volume (one record per UI / FSM transition) so a single mutex
// is fine — no per-handle bucketing needed.
var (
	debugFileMu  sync.Mutex
	debugFile    *os.File
	debugFileErr error
)

// AppendDebugEvent appends one JSON line (caller-encoded) to
// events.jsonl. Opens the file lazily on first call and reuses the
// handle. Newline-terminated. Returns an error only when the open
// or first-line-write fails — subsequent failures are squashed via
// debugFileErr to keep the chunk pump quiet on a misconfigured FS.
//
// Thread-safe; called from gala under any goroutine.
func AppendDebugEvent(line string) error {
	path := EventsPath()
	if path == "" {
		return errDebugNoRepo
	}
	debugFileMu.Lock()
	defer debugFileMu.Unlock()
	if debugFileErr != nil {
		return debugFileErr
	}
	if debugFile == nil {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			debugFileErr = err
			return err
		}
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			debugFileErr = err
			return err
		}
		debugFile = f
	}
	if _, err := debugFile.WriteString(line + "\n"); err != nil {
		debugFileErr = err
		return err
	}
	return nil
}

// ResetDebugDir wipes the entire <repo>/.gala_team/sessions/debug
// tree and closes any cached events.jsonl handle so the next
// AppendDebugEvent re-opens against a fresh file. Used by the
// "Start fresh" recovery flow so a new session starts with a clean
// log slate (no archaeology across resets — events on disk map 1:1
// to the live conversation).
//
// If the dir doesn't exist yet, RemoveAll is a no-op and we just
// drop the handle cache. Returns the underlying RemoveAll error so
// the gala caller can surface it in LastError.
func ResetDebugDir() error {
	debugFileMu.Lock()
	if debugFile != nil {
		_ = debugFile.Close()
		debugFile = nil
	}
	debugFileErr = nil
	debugFileMu.Unlock()
	d := DebugDir()
	if d == "" {
		return nil
	}
	return os.RemoveAll(d)
}

var errDebugNoRepo = errors.New("debug: SetDebugRepo not called yet")
