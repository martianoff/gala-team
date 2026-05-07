// Package runtime — OpenInBrowser helper for the gala-side
// onPrCreated handler. Best-effort opens `url` in the OS default
// browser. Failures are returned to the gala caller so callers
// can surface them via toast / LastError if they care, but for
// the PR-created path the caller (onPrCreated) intentionally
// drops the error: headless / CI contexts have no browser, and
// the OSC 8 hyperlink in the conversation log is the fallback.
package runtime

import (
	"os/exec"
	"runtime"
)

// OpenInBrowser launches the OS default browser pointing at
// `url`. Spawned async (Run not Wait) so we never block the TUI
// pump. Returns nil on success, an error wrapped from exec.Cmd
// on failure (browser not installed, sandboxed env, etc.).
//
// Per-OS commands:
//   - Windows: rundll32 url.dll,FileProtocolHandler  (avoids
//     `cmd /c start` which mangles URL escape characters)
//   - macOS:   open
//   - Linux:   xdg-open
//
// Other GOOSes fall through to xdg-open since most BSD desktops
// ship it; failure on those returns the underlying exec error.
func OpenInBrowser(url string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	return cmd.Start()
}
