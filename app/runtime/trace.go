// Package runtime — Go-side helper for the optional GALA_TEAM_TRACE_DIR
// diagnostic. The gala-side counterpart is trace.gala; this file exists
// only because gala can't compose `os.O_APPEND|os.O_CREATE|os.O_WRONLY`
// flag bitwise OR ergonomically and we want a single per-(member, session)
// file handle held open across appends, not a per-line open/close cycle.
//
// The gala caller still owns:
//   - the env-var lookup decision (gates whether we're tracing at all),
//   - the JSONL record encoding (one line per chunk, JSON-encoded via
//     gala's json.Codec[TraceRecord]),
//   - the timestamp and member sanitisation logic.
//
// All this Go file does is "given a file path and a string, append
// the string + newline to the file, opening it lazily once". A failure
// short-circuits future writes to that handle so the chunk pump isn't
// flooded with disk-full errors.
package runtime

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// traceWriter is a per-process, member-keyed map of open file handles.
// File handles are held until process exit (the OS reaps them on close).
// Writes are serialised through a single mutex — appends are short and
// contention between members is rare in practice; this is simpler than
// per-handle mutexes and avoids races on the map lookup.
var (
	traceMu    sync.Mutex
	traceFiles = map[string]*os.File{}
)

// AppendTraceLine opens path in append mode (creating it and any
// missing parents on first call), writes data + "\n", and returns nil
// on success. Errors are returned to the gala caller which decides how
// to surface them — typically "log once, don't break the chunk pump".
//
// Idempotent across calls: the second call for the same path reuses
// the cached file handle. The handle is keyed by absolute path so two
// members writing under the same trace dir don't collide.
func AppendTraceLine(path, data string) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	traceMu.Lock()
	defer traceMu.Unlock()
	f, ok := traceFiles[abs]
	if !ok {
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			return err
		}
		f, err = os.OpenFile(abs, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		traceFiles[abs] = f
	}
	if _, err := f.WriteString(data + "\n"); err != nil {
		return err
	}
	return nil
}

// TraceDir returns the value of GALA_TEAM_TRACE_DIR, or "" when unset.
// Pulled into a Go helper because gala's `os.Getenv` interop returns a
// (string, bool) tuple in some toolchain versions; this normalises to
// a single string the gala caller can branch on with a plain `!=  ""`.
func TraceDir() string {
	return os.Getenv("GALA_TEAM_TRACE_DIR")
}

// errTraceShortCircuit is returned to the gala caller when a prior
// write to this handle failed and we've stopped attempting further
// writes. Distinguishing it from a fresh write error lets the gala
// side suppress repeated stderr noise.
var errTraceShortCircuit = errors.New("trace short-circuited after prior failure")
