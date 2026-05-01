#!/usr/bin/env bash
# Live audit v2 — uses heredocs in single-quoted form so nested JSON
# strings escape correctly. Drives every code path through the
# test-mode harness with realistic claude stream-json chunks.

set -uo pipefail
BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"
ROOT="/tmp/galateam_live2_$$"
mkdir -p "$ROOT"

OUT="/tmp/galateam_live2_out_$$"
mkdir -p "$OUT"

# Each scenario gets a fresh sandbox so prior conversations don't bleed
# through via persisted .gala_team/conversation.jsonl.
run() {
    local name="$1"
    local sbx="$ROOT/$name"
    mkdir -p "$sbx"
    git -C "$sbx" init --quiet
    cp examples/minimal.yaml "$sbx/team.yaml"
    "$BIN" --test-mode --team "$sbx/team.yaml" --project "$sbx" > "$OUT/${name}.jsonl" 2>&1
    local frames
    frames=$(grep -c '"type":"frame"' "$OUT/${name}.jsonl" || true)
    echo "  ${name}: ${frames} frames"
}

echo "== 1. init filter + assistant text =="
run "01_init_filter" <<'EOF'
{"type":"key","char":"h"}
{"type":"key","char":"i"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"C:\\\\proj\",\"session_id\":\"550e8400-e29b-41d4-a716-446655440000\",\"tools\":[\"Read\",\"Bash\"],\"model\":\"claude-opus-4-7\"}"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"id\":\"msg_01\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hello! I am Lead.\"}]}}"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"result\",\"subtype\":\"success\",\"duration_ms\":1234,\"is_error\":false}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 2. multi-turn =="
run "02_multiturn" <<'EOF'
{"type":"key","char":"h"}
{"type":"key","char":"i"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi back\"}]}}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"key","char":"a"}
{"type":"key","char":"g"}
{"type":"key","char":"a"}
{"type":"key","char":"i"}
{"type":"key","char":"n"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"second response\"}]}}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 3. dispatch + member finished =="
run "03_dispatch" <<'EOF'
{"type":"key","char":"f"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"@dispatch(Eng) please fix\\n@end\"}]}}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"on it"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@finished"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"fixed it all"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Eng","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF
# Sanity check on the dispatch fanout: any frame in Delegating state
# should show Eng either as working (spawn OK) or have a lastError
# mentioning the dispatch (sandbox spawn failed in test mode). If no
# Delegating frame ever shows either, spawnDispatchedMembers didn't
# fire and Eng would stay idle.
PD_HIT=$(grep '"type":"frame"' "$OUT/03_dispatch.jsonl" | grep '"state":"Delegating"' | grep -E '"Eng":"working"|dispatch Eng:' | head -1)
if [ -n "$PD_HIT" ]; then
    echo "    -> dispatch fanout OK"
else
    echo "    !! WARNING: post-dispatch fanout did not fire"
fi

echo "== 4. tool-use rendering =="
run "04_tool_use" <<'EOF'
{"type":"key","char":"r"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Let me check the file.\"},{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"Read\",\"input\":{\"file\":\"main.go\"}}]}}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 5. @summary → Approval =="
run "05_approval" <<'EOF'
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"@summary\\nAll done. PR ready.\\n@end\"}]}}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 6. heartbeat =="
run "06_heartbeat" <<'EOF'
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"working"}
{"type":"snapshot","detail":"plain"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 7. pipe-ended cleanup =="
run "07_pipe_ended" <<'EOF'
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"hello"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"write |1: The pipe has been ended."}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 8. retry exhaustion =="
run "08_retries" <<'EOF'
{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 1"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 2"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"crash 3"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 9. erase session =="
run "09_erase" <<'EOF'
{"type":"key","char":"a"}
{"type":"key","char":"b"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"resp"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 10. recovery =="
run "10_recovery_relaunch" <<'EOF'
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 11. @blocked routing =="
run "11_blocked" <<'EOF'
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@dispatch(Eng) work"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@blocked"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"missing tool gh"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@end"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 15. scrollable chat: PgUp unsticks, End re-sticks =="
run "15_scroll" <<'EOF'
{"type":"key","char":"a"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"line one"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"line two"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"line three"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"PageUp"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"End"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 16. engineer token tracking =="
run "16_eng_tokens" <<'EOF'
{"type":"key","char":"f"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"@dispatch(Eng) please fix\\n@end\"}]}}"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.05,\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"cache_read_input_tokens\":1000}}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"@finished done\\n@end\"}]}}"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.03,\"usage\":{\"input_tokens\":7,\"output_tokens\":15,\"cache_read_input_tokens\":500}}"}
{"type":"msg","name":"SessionFailed","member":"Eng","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 13. rate-limit error event =="
run "13_rate_limit" <<'EOF'
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"result\":\"Rate limit exceeded\"}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 14. unknown event kind =="
run "14_unknown_kind" <<'EOF'
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"control_request\",\"foo\":\"bar\"}"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"answer\"}]}}"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== 12. resize sweep =="
run "12_resize" <<'EOF'
{"type":"resize","cols":80,"rows":24}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":120,"rows":40}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":40,"rows":20}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":200,"rows":60}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "Output: $OUT"
