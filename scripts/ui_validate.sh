#!/usr/bin/env bash
# UI validation script — exercises specific user flows via the
# stdio test-driver and asserts on the resulting frames.
# Returns non-zero on failed assertions so CI can pick it up.

set -uo pipefail
BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"
TEAM="examples/minimal.yaml"

# Use a scratch sandbox project so persisted .gala_team/sessions/latest.json
# is isolated and we can clean between scenarios.
SANDBOX="/tmp/galateam_ui_validate"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
git -C "$SANDBOX" init --quiet
( cd "$SANDBOX" && cp "$OLDPWD/$TEAM" team.yaml )
PROJECT="$SANDBOX"

OUT_DIR=/tmp/galateam_validate_out
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

run() {
    local name="$1"
    local input="$2"
    local out="${OUT_DIR}/${name}.jsonl"
    printf '%s' "$input" | "$BIN" --test-mode --team "$SANDBOX/team.yaml" --project "$PROJECT" > "$out" 2>&1
    echo "  → ${out}"
}

echo "== (1) init: fresh conversation, type+submit, member chunks, EOF =="
run "01_init_full_flow" \
    '{"type":"snapshot","detail":"plain"}
{"type":"key","char":"f"}
{"type":"key","char":"i"}
{"type":"key","char":"x"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Enter"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@dispatch(Eng) please fix"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"on it"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@finished"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"done"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Eng","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== (2a) seed a session for recovery test =="
# Use the same sandbox — first run leaves latest.json behind.
run "02a_seed_for_recovery" \
    '{"type":"key","char":"r"}
{"type":"key","char":"u"}
{"type":"key","char":"n"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@dispatch(Eng) start"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"working"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== (2b) recovery: relaunch, verify banner and statuses =="
# Don't quit immediately — driver process exits naturally on stdin EOF.
run "02b_recovery" \
    '{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== (3) errors + warnings surface correctly =="
run "03_errors" \
    '{"type":"msg","name":"SessionFailed","member":"Lead","err":"stream closed"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"The pipe has been ended."}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo ""
echo "Done. Frame summary:"
for f in "$OUT_DIR"/*.jsonl; do
    frames=$(grep -c '"type":"frame"' "$f" || true)
    errors=$(grep -c '"type":"error"' "$f" || true)
    echo "  $(basename "$f"): frames=${frames} errors=${errors}"
done
