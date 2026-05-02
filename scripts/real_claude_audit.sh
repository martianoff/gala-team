#!/usr/bin/env bash
# Real-claude smoke test — drives the headless binary against the
# actual claude CLI for a few prompts that historically tripped the
# JSON-leak / sanitiser path. Runs OUTSIDE the test-driver so we
# exercise the real subprocess + real claude --output-format
# stream-json output, not synthetic chunk replays.
#
# Requires:
#   - claude on PATH and authenticated
#   - gh on PATH
#   - bazel-bin/cmd/gala_team_headless/gala_team_headless built
#
# Output: each scenario's full conversation log + assertions on the
# rendered text NOT containing stream-json envelope markers.
#
# This is the test that should have caught the base64 leak users hit
# in production. Synthetic chunks can't reproduce gala-codec edge
# cases that real claude triggers.

set -uo pipefail
HEADLESS="$(bazel info bazel-bin)/cmd/gala_team_headless/gala_team_headless.exe"
SBX="/tmp/galateam_real_$$"
mkdir -p "$SBX"
git -C "$SBX" init --quiet
git -C "$SBX" -c user.email=t@t -c user.name=t commit --allow-empty -q -m base
cp examples/minimal.yaml "$SBX/team.yaml"

OUT="/tmp/galateam_real_out_$$"
mkdir -p "$OUT"

if [ ! -x "$HEADLESS" ]; then
    echo "headless binary not found at $HEADLESS — build with:" >&2
    echo "  bazel build cmd/gala_team_headless:gala_team_headless" >&2
    exit 1
fi

run_real() {
    local name="$1"
    local prompt="$2"
    "$HEADLESS" --team "$SBX/team.yaml" --project "$SBX" --prompt "$prompt" \
        > "$OUT/${name}.json" 2> "$OUT/${name}.err.log" || true
    local leaks
    leaks=$(grep -cE '"stop_reason"|"session_id"|"cache_read_input_tokens"|"parent_tool_use_id"' "$OUT/${name}.json" || true)
    case "$leaks" in
        0) echo "  ${name}: clean (no stream-json envelope markers in transcript)";;
        *) echo "  ${name}: !! LEAK ($leaks envelope markers found) — see $OUT/${name}.json";;
    esac
}

echo "== A. trivial chat (baseline) =="
run_real "A_chat" "Reply with just the word 'pong' and nothing else."

echo "== B. base64 output (was the leak repro) =="
run_real "B_base64" "Print the base64 SHA-256 digest of the string 'gala_team test fixture'. Output ONLY the base64 string, no explanation."

echo "== C. long structured output =="
run_real "C_long" "Generate a 30-line numbered list of canonical sorting algorithms. Just the list, no preface."

echo "== D. code block with backticks =="
run_real "D_code" "Write a 5-line gala function that returns the square of an int. Use a fenced code block."

echo ""
echo "Output: $OUT"
echo ""
echo "Run each scenario manually for visual inspection:"
echo "  cat $OUT/A_chat.json"
