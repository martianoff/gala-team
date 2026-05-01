#!/usr/bin/env bash
# UI audit script — drives the test-mode harness through every major
# code path and saves frames for batch inspection. Output goes to
# /tmp/ui_audit.<scenario>.jsonl (one JSON frame per line).
#
# Run from repo root after `bazel build cmd:gala_team`.

set -uo pipefail
BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"
TEAM_MIN="examples/minimal.yaml"
TEAM_FULL="examples/skunkworks.yaml"   # may fail to parse — exercises that path
TEAM_MULTI="examples/multi-team.yaml"  # may fail to parse — exercises that path
PROJECT="."
OUT=/tmp

run() {
    local scenario="$1"
    local team="$2"
    local input="$3"
    local out_file="${OUT}/ui_audit.${scenario}.jsonl"
    echo "=== ${scenario} (team=${team}) ==="
    printf '%s' "$input" | "${BIN}" --test-mode --team "$team" --project "$PROJECT" > "$out_file" 2>&1
    local frames
    frames=$(grep -c '"type":"frame"' "$out_file" || true)
    local errors
    errors=$(grep -c '"type":"error"' "$out_file" || true)
    echo "  frames=${frames}  errors=${errors}  → ${out_file}"
}

# Scenario 1: idle baseline
run "01_idle_minimal" "$TEAM_MIN" \
    '{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 2: 80x24 vs 120x40 vs 160x50 — layout at multiple sizes
run "02_resize_sweep" "$TEAM_MIN" \
    '{"type":"resize","cols":80,"rows":24}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":120,"rows":40}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":160,"rows":50}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":40,"rows":15}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 3: type a prompt + submit (exercises composer + state)
run "03_compose_submit" "$TEAM_MIN" \
    '{"type":"key","char":"h"}
{"type":"key","char":"i"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Enter"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 4: focus toggle + sidebar navigation
run "04_focus_sidebar" "$TEAM_MIN" \
    '{"type":"key","key":"CtrlL"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 5: streamed chunks from members (exercises onChunk + dispatch dir)
run "05_member_chunks" "$TEAM_MIN" \
    '{"type":"key","char":"f"}
{"type":"key","char":"i"}
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@dispatch(Eng) work on it"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@end"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"working on the fix"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"SessionFailed","member":"Eng","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 6: long single-line chunk — text overflow test
run "06_text_overflow" "$TEAM_MIN" \
    '{"type":"msg","name":"ChunkArrived","member":"Lead","line":"this is an extremely long line that should overflow the conversation pane width and either wrap or get truncated — we need to verify which behavior the renderer picks because the user reported that long claude responses get clipped at the right edge instead of wrapping naturally"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 7: heartbeat → slow → stuck → failed (tick storm)
run "07_heartbeat" "$TEAM_MIN" \
    '{"type":"msg","name":"ChunkArrived","member":"Lead","line":"start work"}
{"type":"snapshot","detail":"plain"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 8: SessionFailed non-EOF — auto-retry path
run "08_session_failed_retry" "$TEAM_MIN" \
    '{"type":"msg","name":"SessionFailed","member":"Lead","err":"stream closed"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"stream closed again"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"third strike"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 9: parsing-error team yaml
run "09_yaml_parse_error" "$TEAM_FULL" \
    '{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# Scenario 10: multi-team yaml (also probably fails to parse — same error path)
run "10_multi_team_yaml" "$TEAM_MULTI" \
    '{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo ""
echo "Done. Inspect: ls -la ${OUT}/ui_audit.*.jsonl"
