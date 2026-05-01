#!/usr/bin/env bash
# Drives a series of error/warning conditions and captures styled snapshots
# to verify each lands in the right surface with the right styling.

set -uo pipefail
BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"
SANDBOX="/tmp/galateam_err_$$"
mkdir -p "$SANDBOX"
git -C "$SANDBOX" init --quiet
cp examples/minimal.yaml "$SANDBOX/team.yaml"

OUT="/tmp/galateam_err_out_$$"
mkdir -p "$OUT"

run() {
    local name="$1"
    local input="$2"
    local out="${OUT}/${name}.jsonl"
    printf '%s' "$input" | "$BIN" --test-mode --team "$SANDBOX/team.yaml" --project "$SANDBOX" > "$out" 2>&1
}

# 1: SessionFailed non-EOF → red footer + retry counter in LastError
run "01_session_crash" \
    '{"type":"msg","name":"SessionFailed","member":"Lead","err":"unexpected EOF"}
{"type":"snapshot","detail":"styled"}
{"type":"quit"}'

# 2: pipe-ended → should be clean close (no footer warning)
run "02_pipe_ended" \
    '{"type":"msg","name":"SessionFailed","member":"Lead","err":"write |1: The pipe has been ended."}
{"type":"snapshot","detail":"styled"}
{"type":"quit"}'

# 3: Retries exhausted → StFailed status + final error in footer
run "03_retries_exhausted" \
    '{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 1"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 2"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 3"}
{"type":"snapshot","detail":"styled"}
{"type":"quit"}'

# 4: Member @blocked → StFailed + LastError + toast
run "04_blocked" \
    '{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@blocked"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"missing tool"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@end"}
{"type":"snapshot","detail":"styled"}
{"type":"quit"}'

# 5: Quit pending — yellow warning replaces normal footer
run "05_quit_pending" \
    '{"type":"key","key":"CtrlQ"}
{"type":"snapshot","detail":"styled"}
{"type":"quit"}'

echo "Frame counts:"
for f in "$OUT"/*.jsonl; do
    frames=$(grep -c '"type":"frame"' "$f" || true)
    echo "  $(basename "$f"): ${frames}"
done
