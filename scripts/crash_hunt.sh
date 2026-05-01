#!/usr/bin/env bash
# Crash-hunting script. Each scenario exercises a different code path
# that might trigger an unhandled panic / OOB / nil deref. Captures
# stderr separately so panic stacktraces are visible.

set -uo pipefail
BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"
ROOT="/tmp/crash_hunt_$$"
mkdir -p "$ROOT"
OUT="/tmp/crash_hunt_out_$$"
mkdir -p "$OUT"

probe() {
    local name="$1"
    local sbx="$ROOT/$name"
    mkdir -p "$sbx"
    git -C "$sbx" init --quiet
    cp examples/minimal.yaml "$sbx/team.yaml"
    "$BIN" --test-mode --team "$sbx/team.yaml" --project "$sbx" \
        > "$OUT/${name}.stdout" 2> "$OUT/${name}.stderr"
    local rc=$?
    if [ $rc -ne 0 ] || grep -q "panic:\|runtime error\|Stack trace\|fatal error:" "$OUT/${name}.stderr"; then
        echo "  CRASH: $name (exit=$rc)"
        head -20 "$OUT/${name}.stderr"
        return 1
    else
        echo "  ok: $name"
        return 0
    fi
}

echo "== probe 01: empty input =="
probe "01_empty" </dev/null

echo "== probe 02: malformed JSON command =="
probe "02_malformed_cmd" <<'EOF'
not valid json
{"type":"key","char":"a"}
{"type":"quit"}
EOF

echo "== probe 03: huge prompt =="
probe "03_huge_prompt" <<EOF
$(printf '{"type":"key","char":"x"}\n%.0s' {1..2000})
{"type":"key","key":"Enter"}
{"type":"quit"}
EOF

echo "== probe 04: open member detail with empty team transcript =="
probe "04_modal_empty" <<'EOF'
{"type":"key","key":"Tab"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Down"}
{"type":"key","key":"Enter"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Esc"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 05: rapid PgUp/PgDn/End hammering =="
probe "05_scroll_hammer" <<'EOF'
{"type":"key","char":"a"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"hi"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"key","key":"PageUp"}
{"type":"key","key":"PageUp"}
{"type":"key","key":"PageUp"}
{"type":"key","key":"PageDown"}
{"type":"key","key":"PageDown"}
{"type":"key","key":"End"}
{"type":"key","key":"PageUp"}
{"type":"key","key":"End"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 06: chunk with embedded null/control chars =="
probe "06_weird_chunk" <<'EOF'
{"type":"key","char":"a"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"line\twith\ttabs"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"unicode: 日本語 العربية 🚀"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":""}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 07: unknown member name in chunk =="
probe "07_unknown_member_chunk" <<'EOF'
{"type":"msg","name":"ChunkArrived","member":"Ghost","line":"hi"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 08: malformed claude JSON =="
probe "08_malformed_claude" <<'EOF'
{"type":"key","char":"x"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{not json"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 09: tiny terminal =="
probe "09_tiny_term" <<'EOF'
{"type":"resize","cols":20,"rows":8}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":10,"rows":4}
{"type":"snapshot","detail":"plain"}
{"type":"resize","cols":1,"rows":1}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 10: mouse outside any panel =="
probe "10_mouse_oob" <<'EOF'
{"type":"mouse","x":-1,"y":-1,"pressed":true}
{"type":"mouse","x":9999,"y":9999,"pressed":true}
{"type":"mouse","x":0,"y":0,"pressed":false}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 11: erase mid-stream =="
probe "11_erase_midstream" <<'EOF'
{"type":"key","char":"a"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"streaming..."}
{"type":"key","key":"CtrlN"}
{"type":"key","key":"CtrlN"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 12: yank empty conversation =="
probe "12_yank_empty" <<'EOF'
{"type":"key","key":"CtrlY"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "== probe 13: modal on tiny terminal =="
probe "13_modal_tiny" <<'EOF'
{"type":"resize","cols":20,"rows":8}
{"type":"key","key":"Tab"}
{"type":"key","key":"Down"}
{"type":"key","key":"Enter"}
{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Esc"}
{"type":"quit"}
EOF

echo "== probe 14: heavy traffic interleaved =="
probe "14_heavy_traffic" <<'EOF'
{"type":"key","char":"a"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"chunk 1\"}]}}"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"chunk 2"}
{"type":"tick"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"chunk 3"}
{"type":"tick"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"@dispatch(Eng) work\n@end"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"on it"}
{"type":"tick"}
{"type":"msg","name":"ChunkArrived","member":"Eng","line":"@finished done\n@end"}
{"type":"msg","name":"SessionFailed","member":"Eng","err":"EOF"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}
EOF

echo "Output: $OUT"
