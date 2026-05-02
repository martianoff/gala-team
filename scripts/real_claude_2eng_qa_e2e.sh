#!/usr/bin/env bash
# Multi-member real-claude E2E: 2 engineers + 1 QA + lead, all driven
# against the actual `claude` CLI via gala_team_headless.
#
# What we exercise:
#   1. Lead picks engineers and dispatches in parallel.
#   2. Each engineer edits + commits their slice.
#   3. QA reviews the combined deliverable manifest.
#   4. Lead emits @summary.
#   5. gh pr create runs against a fakegh stand-in.
#
# Why we orchestrate manually instead of using the interactive TUI:
# the test driver discards Cmds, so the FSM dispatch fan-out doesn't
# actually spawn claude subprocesses. Manual orchestration via
# gala_team_headless --member <name> exercises the SAME claude
# invocations the live TUI would run, but with deterministic shell
# scheduling so the script can assert on each step.

set -uo pipefail
HEADLESS="$(bazel info bazel-bin)/cmd/gala_team_headless/gala_team_headless_/gala_team_headless.exe"

if [ ! -x "$HEADLESS" ]; then
    echo "headless binary not found at $HEADLESS" >&2
    echo "build with: bazel build cmd/gala_team_headless:gala_team_headless" >&2
    exit 1
fi
if ! command -v node >/dev/null 2>&1; then
    echo "node required to extract JSON fields from headless output" >&2
    exit 1
fi

REPO="${1:-/tmp/gtmulti}"
TEAM="$REPO/team.yaml"
OUT="/tmp/galateam_2eng_$$"
mkdir -p "$OUT"
echo "=== E2E: $REPO  ==>  $OUT ==="
echo ""

# Helper: extract a JSON field from a headless output file.
jget() {
    local file="$1"
    local field="$2"
    node -e "
        let s='';
        process.stdin.on('data',d=>s+=d);
        process.stdin.on('end',()=>{
            try {
                const d = JSON.parse(s);
                const v = d['$field'];
                if (v === null || v === undefined) process.exit(0);
                process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
            } catch(e) {
                process.exit(0);
            }
        });
    " < "$file"
}

# fakegh on PATH so gh pr create doesn't hit real GitHub.
mkdir -p "$OUT/bin"
cat > "$OUT/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1 $2" = "pr create" ]; then
    echo "https://github.com/example/example/pull/108"
    exit 0
fi
echo "fakegh: unsupported $@" >&2
exit 1
FAKEGH
chmod +x "$OUT/bin/gh"
export PATH="$OUT/bin:$PATH"

echo "[1/5] Iris: kick off the dispatch"
"$HEADLESS" \
    --team "$TEAM" --project "$REPO" --member "Iris" \
    --prompt "calc.go has add() and mul() with no input validation. Plan: dispatch BOTH engineers in parallel. Felix takes add(), Mira takes mul(). Each engineer should add a guard for negative inputs (return 0 with a comment) and commit their change. After both finish I'll have Theo review and emit @summary. Reply with ONLY the directive block: @dispatch(Felix) ... @end then @dispatch(Mira) ... @end. Be concise — one paragraph each." \
    > "$OUT/01_iris.json" 2> "$OUT/01_iris.err"
IRIS_TEXT=$(jget "$OUT/01_iris.json" "summary"; cat "$OUT/01_iris.json" | node -e "let s=''; process.stdin.on('data',d=>s+=d); process.stdin.on('end',()=>{const d=JSON.parse(s); d.conversation.filter(c=>c.speaker==='Iris').forEach(c=>console.log(c.text))})")
echo "$IRIS_TEXT" | head -8
echo "..."

# Pull the dispatch bodies via crude regex — Felix and Mira each get
# what's between their @dispatch line and the matching @end.
FELIX_BODY=$(echo "$IRIS_TEXT" | awk '/@dispatch\(Felix\)/,/@end/' | sed '1d;$d')
MIRA_BODY=$(echo "$IRIS_TEXT" | awk '/@dispatch\(Mira\)/,/@end/' | sed '1d;$d')
if [ -z "$FELIX_BODY" ] || [ -z "$MIRA_BODY" ]; then
    echo "  !! Iris didn't emit both @dispatch directives — see $OUT/01_iris.json"
    exit 1
fi
echo "  -> Iris dispatched Felix + Mira"
echo ""

echo "[2/5] Felix: implement add() guard + commit"
NL=$'\n'
FELIX_PROMPT="$FELIX_BODY${NL}${NL}When done, commit your change with a clear message and reply with @finished listing the file path and commit hash, then @end."
"$HEADLESS" \
    --team "$TEAM" --project "$REPO" --member "Felix" \
    --prompt "$FELIX_PROMPT" \
    > "$OUT/02_felix.json" 2> "$OUT/02_felix.err"
FELIX_REPORT=$(cat "$OUT/02_felix.json" | node -e "let s=''; process.stdin.on('data',d=>s+=d); process.stdin.on('end',()=>{const d=JSON.parse(s); d.conversation.filter(c=>c.speaker==='Felix').forEach(c=>console.log(c.text))})")
echo "$FELIX_REPORT" | head -6
echo "..."
echo ""

echo "[3/5] Mira: implement mul() guard + commit"
MIRA_PROMPT="$MIRA_BODY${NL}${NL}When done, commit your change with a clear message and reply with @finished listing the file path and commit hash, then @end."
"$HEADLESS" \
    --team "$TEAM" --project "$REPO" --member "Mira" \
    --prompt "$MIRA_PROMPT" \
    > "$OUT/03_mira.json" 2> "$OUT/03_mira.err"
MIRA_REPORT=$(cat "$OUT/03_mira.json" | node -e "let s=''; process.stdin.on('data',d=>s+=d); process.stdin.on('end',()=>{const d=JSON.parse(s); d.conversation.filter(c=>c.speaker==='Mira').forEach(c=>console.log(c.text))})")
echo "$MIRA_REPORT" | head -6
echo "..."
echo ""

echo "[4/5] Theo: QA reviews both engineer commits"
QA_PROMPT="Engineers reported back. Felix said: $FELIX_REPORT
Mira said: $MIRA_REPORT
Run 'git log --oneline -5' to verify both commits exist and 'cat calc.go' to confirm both add() and mul() now have negative-input guards. Reply with @finished if both pass review (mention 'reviewed N files' so the lead knows what you checked) or @blocked if anything is missing, then @end. Be concise — one paragraph."
"$HEADLESS" \
    --team "$TEAM" --project "$REPO" --member "Theo" \
    --prompt "$QA_PROMPT" \
    > "$OUT/04_theo.json" 2> "$OUT/04_theo.err"
QA_VERDICT=$(cat "$OUT/04_theo.json" | node -e "let s=''; process.stdin.on('data',d=>s+=d); process.stdin.on('end',()=>{const d=JSON.parse(s); d.conversation.filter(c=>c.speaker==='Theo').forEach(c=>console.log(c.text))})")
echo "$QA_VERDICT" | head -10
echo "..."
if echo "$QA_VERDICT" | grep -q '@blocked'; then
    echo "  !! QA blocked the change — see $OUT/04_theo.json"
    exit 1
fi
echo "  -> QA approved"
echo ""

echo "[5/5] Iris: emit final @summary"
SUMMARY_PROMPT="The team is done. Felix: $FELIX_REPORT
Mira: $MIRA_REPORT
Theo (QA): $QA_VERDICT
Compose a final @summary block listing the files touched, the commits, and the QA verdict. Then @end. Title-style first line so it can become a PR title."
"$HEADLESS" \
    --team "$TEAM" --project "$REPO" --member "Iris" \
    --prompt "$SUMMARY_PROMPT" \
    > "$OUT/05_summary.json" 2> "$OUT/05_summary.err"
SUMMARY=$(jget "$OUT/05_summary.json" "summary")
if [ -z "$SUMMARY" ]; then
    echo "  !! Iris didn't emit @summary — see $OUT/05_summary.json"
    exit 1
fi
echo "Summary:"
echo "$SUMMARY" | head -10
echo ""

echo "[gh] approval pre-check + gh pr create"
PR_AHEAD=$(git -C "$REPO" rev-list --count main..HEAD)
echo "  commits ahead of main: $PR_AHEAD"
if [ "$PR_AHEAD" = "0" ]; then
    echo "  !! no commits — engineers didn't actually edit anything"
    exit 1
fi
TITLE=$(echo "$SUMMARY" | head -1 | head -c 72)
PR_URL=$("$OUT/bin/gh" pr create --title "$TITLE" --body "$SUMMARY")
echo "  PR: $PR_URL"
echo ""

echo "=== E2E COMPLETE ==="
echo "  Output: $OUT"
echo "  Commits added: $PR_AHEAD"
echo "  PR URL: $PR_URL"
