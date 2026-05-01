#!/usr/bin/env bash
# Thorough self-audit script — exercises every UI flow with the test
# driver and captures detailed snapshots so the analyzer can flag every
# visible bug in one pass.

set -uo pipefail
BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"
SBX="/tmp/galateam_thorough_$$"
mkdir -p "$SBX"
git -C "$SBX" init --quiet
cp examples/minimal.yaml "$SBX/team.yaml"

OUT="/tmp/galateam_thorough_out_$$"
mkdir -p "$OUT"

run() {
    local name="$1"
    local input="$2"
    local out_file="${OUT}/${name}.jsonl"
    printf '%s' "$input" | "$BIN" --test-mode --team "$SBX/team.yaml" --project "$SBX" > "$out_file" 2>&1
    local frames
    frames=$(grep -c '"type":"frame"' "$out_file" || true)
    echo "  ${name}: frames=${frames}  →  ${out_file}"
}

echo "== A. fresh init =="
run "A_init" \
    '{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== B. type 'hi' + submit =="
run "B_hi_submit" \
    '{"type":"key","char":"h"}
{"type":"key","char":"i"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Enter"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== C. TL responds with simple text =="
run "C_tl_text_response" \
    '{"type":"key","char":"h"}
{"type":"key","char":"i"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"hello back"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== D. TL dispatches; member responds; relay =="
run "D_full_dispatch" \
    '{"type":"key","char":"f"}
{"type":"key","char":"i"}
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@dispatch(Eng) please fix"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"on it"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@finished"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"done it"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Eng","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== E. TL @summary triggers Approval =="
run "E_approval" \
    '{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@summary"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"all clean"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@end"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== F. terminal size sweep =="
run "F_sizes" \
    '{"type":"resize","cols":80,"rows":24}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":120,"rows":40}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":40,"rows":15}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":200,"rows":60}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":80,"rows":10}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":80,"rows":7}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== G. focus toggle + back =="
run "G_focus" \
    '{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlL"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlL"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== H. heartbeat tick storm =="
run "H_heartbeat" \
    '{"type":"msg","name":"ChunkArrived","member":"Lead","line":"working"}
{"type":"snapshot","detail":"plain"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"tick"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== I. Ctrl+N erase confirm =="
run "I_erase_confirm" \
    '{"type":"key","char":"a"}
{"type":"key","char":"b"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "== J. Ctrl+N then Esc cancel =="
run "J_erase_cancel" \
    '{"type":"key","char":"x"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Esc"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}'

echo "Done. Output: $OUT"
