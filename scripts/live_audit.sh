#!/usr/bin/env bash
# Live-flow audit — drives the test-mode harness with REAL-shaped claude
# stream-json chunks to exercise every code path: init noise filter,
# JSON Codec, multi-turn conversation, dispatch+finished, summary→approval,
# heartbeat escalation, auto-retry, erase-session, recovery.

set -uo pipefail
BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"
SBX="/tmp/galateam_live_$$"
mkdir -p "$SBX"
git -C "$SBX" init --quiet
cp examples/minimal.yaml "$SBX/team.yaml"

OUT="/tmp/galateam_live_out_$$"
mkdir -p "$OUT"

# Real-shaped claude stream-json envelopes (escapes pre-baked).
INIT_CHUNK='{"type":"system","subtype":"init","cwd":"C:\\\\Users\\\\maxmr\\\\GolandProjects\\\\gala_team","session_id":"550e8400-e29b-41d4-a716-446655440000","tools":["Read","Write","Bash"],"model":"claude-opus-4-7"}'
ASSISTANT_TEXT='{"type":"assistant","message":{"id":"msg_01","role":"assistant","content":[{"type":"text","text":"Hello! I am Lead. How can I help?"}]}}'
ASSISTANT_DISPATCH='{"type":"assistant","message":{"id":"msg_02","role":"assistant","content":[{"type":"text","text":"I will fan this out.\n@dispatch(Eng) please find and fix bugs\n@end"}]}}'
ASSISTANT_TOOL_USE='{"type":"assistant","message":{"id":"msg_03","content":[{"type":"text","text":"Let me check the file."},{"type":"tool_use","id":"toolu_01","name":"Read","input":{"file":"main.go"}}]}}'
ASSISTANT_SUMMARY='{"type":"assistant","message":{"id":"msg_04","content":[{"type":"text","text":"@summary\nAll done. PR ready.\n@end"}]}}'
RESULT_OK='{"type":"result","subtype":"success","duration_ms":1234,"is_error":false,"num_turns":1,"session_id":"550e8400-e29b-41d4-a716-446655440000"}'

run() {
    local name="$1"
    local input="$2"
    printf '%s' "$input" | "$BIN" --test-mode --team "$SBX/team.yaml" --project "$SBX" > "$OUT/${name}.jsonl" 2>&1
    local frames
    frames=$(grep -c '"type":"frame"' "$OUT/${name}.jsonl" || true)
    echo "  ${name}: ${frames} frames"
}

# 1. Pure init chunk (the noise that should be filtered)
echo "== 1. init-chunk filter =="
run "01_init_filter" \
"{\"type\":\"key\",\"char\":\"h\"}
{\"type\":\"key\",\"char\":\"i\"}
{\"type\":\"key\",\"key\":\"Enter\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${INIT_CHUNK@Q}}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${ASSISTANT_TEXT@Q}}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${RESULT_OK@Q}}
{\"type\":\"msg\",\"name\":\"SessionFailed\",\"member\":\"Lead\",\"err\":\"EOF\"}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"quit\"}"

# 2. Multi-turn (second message must work)
echo "== 2. multi-turn =="
run "02_multiturn" \
"{\"type\":\"key\",\"char\":\"h\"}
{\"type\":\"key\",\"char\":\"i\"}
{\"type\":\"key\",\"key\":\"Enter\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${INIT_CHUNK@Q}}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${ASSISTANT_TEXT@Q}}
{\"type\":\"msg\",\"name\":\"SessionFailed\",\"member\":\"Lead\",\"err\":\"EOF\"}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"key\",\"char\":\"a\"}
{\"type\":\"key\",\"char\":\"g\"}
{\"type\":\"key\",\"char\":\"a\"}
{\"type\":\"key\",\"char\":\"i\"}
{\"type\":\"key\",\"char\":\"n\"}
{\"type\":\"key\",\"key\":\"Enter\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${ASSISTANT_TEXT@Q}}
{\"type\":\"msg\",\"name\":\"SessionFailed\",\"member\":\"Lead\",\"err\":\"EOF\"}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"quit\"}"

# 3. Dispatch + member finished + relay
echo "== 3. dispatch+finished =="
run "03_dispatch" \
"{\"type\":\"key\",\"char\":\"f\"}
{\"type\":\"key\",\"key\":\"Enter\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${ASSISTANT_DISPATCH@Q}}
{\"type\":\"msg\",\"name\":\"SessionFailed\",\"member\":\"Lead\",\"err\":\"EOF\"}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Eng\",\"line\":\"on it\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Eng\",\"line\":\"@finished\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Eng\",\"line\":\"fixed it all\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Eng\",\"line\":\"@end\"}
{\"type\":\"msg\",\"name\":\"SessionFailed\",\"member\":\"Eng\",\"err\":\"EOF\"}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"quit\"}"

# 4. Tool-use rendering
echo "== 4. tool-use rendering =="
run "04_tool_use" \
"{\"type\":\"key\",\"char\":\"r\"}
{\"type\":\"key\",\"key\":\"Enter\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${ASSISTANT_TOOL_USE@Q}}
{\"type\":\"msg\",\"name\":\"SessionFailed\",\"member\":\"Lead\",\"err\":\"EOF\"}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"quit\"}"

# 5. @summary triggers Approval
echo "== 5. @summary → Approval =="
run "05_approval" \
"{\"type\":\"key\",\"char\":\"x\"}
{\"type\":\"key\",\"key\":\"Enter\"}
{\"type\":\"msg\",\"name\":\"ChunkArrived\",\"member\":\"Lead\",\"line\":${ASSISTANT_SUMMARY@Q}}
{\"type\":\"msg\",\"name\":\"SessionFailed\",\"member\":\"Lead\",\"err\":\"EOF\"}
{\"type\":\"snapshot\",\"detail\":\"plain\"}
{\"type\":\"quit\"}"

# 6. Heartbeat escalation: slow→stuck path (need many ticks)
echo "== 6. heartbeat escalation =="
run "06_heartbeat" \
'{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"working"}
{"type":"snapshot","detail":"plain"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# 7. Pipe-ended (Windows clean close)
echo "== 7. pipe-ended cleanup =="
run "07_pipe_ended" \
'{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"hello"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"write |1: The pipe has been ended."}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# 8. Crash retry exhaustion
echo "== 8. retry exhaustion =="
run "08_retries" \
'{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 1"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 2"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 3"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# 9. Erase session: fresh state after second Ctrl+N
echo "== 9. erase session =="
run "09_erase" \
'{"type":"key","char":"a"}
{"type":"key","char":"b"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"resp"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# 10. Recovery: second launch sees prior session
echo "== 10. recovery =="
run "10_recovery_relaunch" \
'{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# 11. @blocked — directive-with-end timing
echo "== 11. @blocked routing =="
run "11_blocked" \
'{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@dispatch(Eng) work"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@blocked"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"missing tool gh"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@end"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

# 12. Resize sweep — header survival check
echo "== 12. resize sweep =="
run "12_resize" \
'{"type":"resize","cols":80,"rows":24}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":120,"rows":40}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":40,"rows":20}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":200,"rows":60}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo ""
echo "Output: $OUT"
