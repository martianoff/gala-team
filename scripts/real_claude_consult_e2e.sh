#!/usr/bin/env bash
# Cross-team @consult E2E: a main team's lead asks a sibling team
# (transpiler) for help, and the response feeds back into the main
# team's transcript. Drives both teams against actual claude.
#
# Two repos:
#   $MAIN_REPO    — auth-service-style project; team Skunkworks
#   $CONSULT_REPO — gala_simple-style project; team Atlas (transpiler)
#
# Flow:
#   1. Iris (Skunkworks lead) emits `@consult(transpiler) ... @end`.
#   2. We extract the consult body.
#   3. Spawn the consult team's headless against $CONSULT_REPO with
#      the consult body as the prompt.
#   4. Verify the consult team's lead responds with @summary.
#   5. Feed the summary back to Iris as a follow-up turn; Iris emits
#      her own @summary.
#   6. gh pr create runs against fakegh.

set -uo pipefail
HEADLESS="$(bazel info bazel-bin)/cmd/gala_team_headless/gala_team_headless_/gala_team_headless.exe"

if [ ! -x "$HEADLESS" ]; then
    echo "headless binary not found at $HEADLESS" >&2
    exit 1
fi
if ! command -v node >/dev/null 2>&1; then
    echo "node required" >&2
    exit 1
fi

OUT="/tmp/galateam_consult_$$"
mkdir -p "$OUT/bin"
echo "=== consult E2E: $OUT ==="

cat > "$OUT/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
[ "$1 $2" = "pr create" ] && echo "https://github.com/example/example/pull/777" && exit 0
exit 1
FAKEGH
chmod +x "$OUT/bin/gh"
export PATH="$OUT/bin:$PATH"

jget() {
    node -e "let s=''; process.stdin.on('data',d=>s+=d); process.stdin.on('end',()=>{try{const d=JSON.parse(s); const v=d['$2']; if (v) process.stdout.write(typeof v==='string' ? v : JSON.stringify(v))}catch(_){}})" < "$1"
}
spoken_by() {
    node -e "let s=''; process.stdin.on('data',d=>s+=d); process.stdin.on('end',()=>{try{const d=JSON.parse(s); d.conversation.filter(c=>c.speaker==='$2').forEach(c=>console.log(c.text))}catch(_){}})" < "$1"
}

# ----- SETUP REPOS ----------------------------------------------------------
MAIN_REPO="$OUT/main_repo"
CONSULT_REPO="$OUT/consult_repo"
mkdir -p "$MAIN_REPO" "$CONSULT_REPO"

# Main repo — fake auth service that uses a buggy transpiler helper.
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
cat > "$MAIN_REPO/auth.go" <<'EOF'
package main

import "fmt"

// authenticate calls verifyToken; verifyToken depends on a transpiler
// helper that the consult team owns.
func authenticate(token string) bool {
    return verifyToken(token)
}

func verifyToken(t string) bool {
    return t == "ok"
}

func main() { fmt.Println(authenticate("ok")) }
EOF
git -C "$MAIN_REPO" -c user.email=t@t -c user.name=t add auth.go
git -C "$MAIN_REPO" -c user.email=t@t -c user.name=t commit -q -m "add auth.go"
cat > "$MAIN_REPO/team.yaml" <<'EOF'
teams:
  - key: main
    name: "Skunkworks"
    description: "Main team — lead consults the transpiler team for language questions"
    dangerously_skip_permissions: true
    members:
      - role: team_lead
        name: "Iris"
        personality: "Decides quickly. Defers to the transpiler team on language questions."
      - role: engineer
        name: "Felix"
        personality: "Implements the auth changes."
workflow:
  qa_required: false
EOF
mkdir -p "$MAIN_REPO/.gala_team"
cat > "$MAIN_REPO/.gala_team/consults.yaml" <<EOF
consults:
  - name: transpiler
    repo: $CONSULT_REPO
    team: $CONSULT_REPO/team.yaml
EOF

# Consult repo — fake transpiler project.
git -C "$CONSULT_REPO" init -q -b main
git -C "$CONSULT_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
cat > "$CONSULT_REPO/copy.go" <<'EOF'
package main

// Copy is the deep-copy helper. Recently rewritten; field receivers
// for chained access may infer the wrong type per the user report.
func Copy(src, dst interface{}) {
    // ...
}
EOF
git -C "$CONSULT_REPO" -c user.email=t@t -c user.name=t add copy.go
git -C "$CONSULT_REPO" -c user.email=t@t -c user.name=t commit -q -m "add copy.go"
cat > "$CONSULT_REPO/team.yaml" <<'EOF'
teams:
  - key: main
    name: "Atlas"
    description: "Transpiler team — language internals, codegen edge cases"
    dangerously_skip_permissions: true
    members:
      - role: team_lead
        name: "Theodora"
        personality: "Precise. Cites the language spec. Replies with a single @summary."
      - role: engineer
        name: "Cade"
        personality: "Pragmatic compiler engineer."
workflow:
  qa_required: false
EOF

echo "  main repo:    $MAIN_REPO"
echo "  consult repo: $CONSULT_REPO"
echo ""

# ----- STEP 1: Iris asks the transpiler team -------------------------------
echo "[1/4] Iris (main team) emits @consult(transpiler)"
"$HEADLESS" \
    --team "$MAIN_REPO/team.yaml" --project "$MAIN_REPO" --member "Iris" \
    --prompt "Felix found a transpiler bug in the Copy() helper while implementing auth — chained field access infers the wrong receiver type. The transpiler team owns this. Reply with ONE @consult(transpiler) directive that asks them: 'Is this a real bug? Workaround acceptable?' Be concise — under 5 lines in the consult body. Then @end. Do NOT emit @summary." \
    > "$OUT/01_iris_consult.json" 2> "$OUT/01_iris_consult.err"
IRIS_OUT=$(spoken_by "$OUT/01_iris_consult.json" "Iris")
echo "$IRIS_OUT" | head -8
echo "..."
CONSULT_BODY=$(echo "$IRIS_OUT" | awk '/@consult\(transpiler\)/,/@end/' | sed '1d;$d')
if [ -z "$CONSULT_BODY" ]; then
    echo "  !! Iris didn't emit @consult — see $OUT/01_iris_consult.json"
    exit 1
fi
echo "  -> consult body extracted ($(echo "$CONSULT_BODY" | wc -l) lines)"
echo ""

# ----- STEP 2: spawn the consult team's lead -------------------------------
echo "[2/4] Atlas (consult team) responds"
NL=$'\n'
ATLAS_PROMPT="$CONSULT_BODY${NL}${NL}Answer the question DIRECTLY — do NOT @dispatch. Read copy.go yourself, decide if it's a real transpiler bug, and reply with ONE @summary block stating: (a) is it a real bug? (b) what workaround can the auth team use today? Then @end. Single response, no engineer hand-off."
"$HEADLESS" \
    --team "$CONSULT_REPO/team.yaml" --project "$CONSULT_REPO" --member "Theodora" \
    --prompt "$ATLAS_PROMPT" \
    > "$OUT/02_atlas_summary.json" 2> "$OUT/02_atlas_summary.err"
ATLAS_SUMMARY=$(jget "$OUT/02_atlas_summary.json" "summary")
if [ -z "$ATLAS_SUMMARY" ]; then
    echo "  !! Atlas didn't emit @summary — see $OUT/02_atlas_summary.json"
    exit 1
fi
echo "Atlas summary:"
echo "$ATLAS_SUMMARY" | head -10
echo "..."
echo ""

# ----- STEP 3: feed back to Iris ------------------------------------------
echo "[3/4] Iris incorporates the consult result"
SUMMARY_PROMPT="The transpiler team (Atlas) replied to your @consult: $ATLAS_SUMMARY
Now compose YOUR own @summary listing the workaround Iris will apply. Then @end. Title-style first line."
"$HEADLESS" \
    --team "$MAIN_REPO/team.yaml" --project "$MAIN_REPO" --member "Iris" \
    --prompt "$SUMMARY_PROMPT" \
    > "$OUT/03_iris_final.json" 2> "$OUT/03_iris_final.err"
IRIS_SUMMARY=$(jget "$OUT/03_iris_final.json" "summary")
if [ -z "$IRIS_SUMMARY" ]; then
    echo "  !! Iris didn't emit final @summary — see $OUT/03_iris_final.json"
    exit 1
fi
echo "Iris final summary:"
echo "$IRIS_SUMMARY" | head -10
echo "..."
echo ""

# ----- STEP 4: PR ---------------------------------------------------------
echo "[4/4] gh pr create"
git -C "$MAIN_REPO" checkout -q -b feat/consult-fix
git -C "$MAIN_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m "auth: apply transpiler workaround per consult"
TITLE=$(echo "$IRIS_SUMMARY" | head -1 | head -c 72)
PR_URL=$("$OUT/bin/gh" pr create --title "$TITLE" --body "$IRIS_SUMMARY")
echo "  PR: $PR_URL"
echo ""
echo "=== consult E2E COMPLETE ==="
echo "  main:    $MAIN_REPO"
echo "  consult: $CONSULT_REPO"
echo "  PR URL:  $PR_URL"
