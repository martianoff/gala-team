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
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"time"
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
	debugFileMu sync.Mutex
	debugFile   *os.File
)

// AppendDebugEvent appends one JSON line (caller-encoded) to
// events.jsonl. Opens the file lazily on first call and reuses the
// handle. Newline-terminated.
//
// Recoverable failures (file got closed out from under us, the disk
// hiccupped, antivirus briefly locked the file on Windows) close the
// cached handle so the NEXT call retries the open fresh. Past behaviour
// latched the first error into a sticky errDebugX state — a single
// transient open / write failure permanently disabled the audit log
// for the rest of the session, and the silence-after-error symptom
// looked indistinguishable from the orchestrator's event loop being
// dead. Investigating a live "Sable stuck for 13 minutes" report
// found events.jsonl frozen for the same duration while the
// orchestrator was in fact still running; clearing the latch fixes
// that diagnostic dead-end without changing the happy path.
//
// f.Sync after the write forces the OS page cache to disk so a
// concurrent reader (operator running `tail -f` or `Get-Content`)
// sees fresh records as they're emitted, not minutes later when
// Windows decides to flush. events.jsonl writes are infrequent
// (one per FSM transition / member chunk), so the Sync overhead is
// negligible vs. the diagnostic value.
//
// Thread-safe; called from gala under any goroutine.
func AppendDebugEvent(line string) error {
	path := EventsPath()
	if path == "" {
		return errDebugNoRepo
	}
	debugFileMu.Lock()
	defer debugFileMu.Unlock()
	if debugFile == nil {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		debugFile = f
	}
	if _, err := debugFile.WriteString(line + "\n"); err != nil {
		// Drop the cached handle — the next call retries the open.
		// A WriteString failure usually means the underlying file
		// got rotated / unlinked / locked; clinging to a dead
		// handle would silently swallow every subsequent event.
		_ = debugFile.Close()
		debugFile = nil
		return err
	}
	// Best-effort flush. A Sync failure isn't fatal — the data is in
	// the kernel buffer regardless, and the next write will succeed.
	// We surface the original write success rather than the Sync
	// error so the caller's retry logic (if any) doesn't double-
	// count on a slow-disk hiccup.
	_ = debugFile.Sync()
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
	debugFileMu.Unlock()
	d := DebugDir()
	if d == "" {
		return nil
	}
	return os.RemoveAll(d)
}

var errDebugNoRepo = errors.New("debug: SetDebugRepo not called yet")

// ----- crash capture --------------------------------------------------
//
// A panic on the TUI's foreground goroutine unwinds THROUGH the gala-tui
// runtime (running its terminal-restore defers) and would otherwise
// print a raw multi-goroutine dump to stderr and die. In a real terminal
// that dump scrolls the panic header — the one line that names the
// faulting frame — off the top, and when GALA_TEAM_DEBUG is off nothing
// durable is written at all, so the crash is undiagnosable. RunGuarded
// recovers the panic at the top of the run and captures the faulting
// goroutine's stack to a file the operator can actually read.

// crashDir returns the directory crash reports are written to. Prefers
// the registered debug dir (alongside events.jsonl) so reports sit with
// the rest of the session's forensics; falls back to a stable temp dir
// when no repo has been registered yet (e.g. a crash before/at startup).
// Unlike the events log, this is intentionally INDEPENDENT of
// GALA_TEAM_DEBUG — a crash is always worth a trace.
func crashDir() string {
	if d := DebugDir(); d != "" {
		return d
	}
	return filepath.Join(os.TempDir(), "gala_team-crashes")
}

// writeCrashReport persists the panic value plus the faulting
// goroutine's stack to crash-<pid>-<utc>.txt and returns the path it
// wrote, or "" if the report could not be written (out of disk, dir not
// creatable). Best-effort: a failure here must not mask the original
// crash, so the caller treats "" as "no report, fall back to stderr".
func writeCrashReport(panicMsg string, stack []byte) string {
	dir := crashDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return ""
	}
	name := fmt.Sprintf("crash-%d-%s.txt", os.Getpid(),
		time.Now().UTC().Format("20060102T150405Z"))
	path := filepath.Join(dir, name)
	var b strings.Builder
	b.WriteString("gala_team crash report\n")
	b.WriteString("panic: ")
	b.WriteString(panicMsg)
	b.WriteString("\n\n")
	b.Write(stack)
	if len(stack) == 0 || stack[len(stack)-1] != '\n' {
		b.WriteString("\n")
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		return ""
	}
	return path
}

// RunGuarded executes run with a top-level panic recover. On a clean
// return it reports crashed=false. On a panic it captures the panic
// value and the faulting goroutine's stack (debug.Stack() inside the
// deferred recover still includes the frames down to the panic site),
// writes a crash report, and returns crashed=true with the panic
// message and the report path ("" if the report could not be written).
//
// Terminal restoration is NOT this function's concern: the gala-tui
// runtime's own unwinding defers (term.Restore / alt-screen-off) run as
// the panic propagates THROUGH it, before reaching this recover. The
// caller decides what to log and how to exit.
func RunGuarded(run func()) (crashed bool, panicMsg string, reportPath string) {
	defer func() {
		if r := recover(); r != nil {
			crashed = true
			panicMsg = fmt.Sprint(r)
			reportPath = writeCrashReport(panicMsg, debug.Stack())
		}
	}()
	run()
	return false, "", ""
}
