---
description: Drive end-to-end tests for gala_team against actual claude — exercise multi-member orchestration, cross-team consult, approval flow, recovery, and surface UX / JSON-leak / usability bugs. TRIGGER when the user asks to "run e2e", "smoke test", "verify gala_team", "exercise all flows", "find bugs", or "check for json leaks".
user-invocable: true
---

# gala_team end-to-end test driver

Run real-claude end-to-end scenarios against the gala_team binary, then produce a comprehensive analysis covering UX, user flows, code quality, bug detection, JSON leaks, and usability. Used to catch regressions that synthetic test-driver replays miss — gala's JSON codec, claude's stream-json output, and the orchestrator FSM all have edge cases that only show up with real subprocesses.

**Argument:** `$ARGUMENTS` — Optional comma-separated scenario list (default: run all). Available scenarios:
- `solo` — Single lead, real claude edits + commits, gh pr create.
- `2eng_qa` — 2 engineers + QA, parallel dispatch, deliverable manifest, summary.
- `consult` — Cross-team `@consult` between two repos.
- `recovery` — Start fresh / Esc / quit-reopen leftover-data check.
- `worktrees` — `worktree-per-engineer` mode + cleanup on Start fresh.
- `leak` — Synthetic scenarios that historically tripped JSON-leak guards.

## Prerequisites

Run from the gala_team repo root. The skill needs:
- `bazel` on PATH and a built `gala_team` + `gala_team_headless` binary
- `claude` on PATH and authenticated
- `node` on PATH (used to extract JSON fields from headless output)
- `git` on PATH

Build first if either binary is stale:
```bash
bazel build cmd:gala_team cmd/gala_team_headless:gala_team_headless
```

## Instructions

### Step 1 — Sanity-check the build

Run `bazel test app/...`. If anything fails, **stop** and report — broken unit tests mean the binary can't be trusted. Don't run E2E against a red build.

### Step 2 — Run requested scenarios

Each scenario is a self-contained shell script under `scripts/`. Run sequentially so output dirs don't collide. Capture stdout to `/tmp/galateam_skill_<scenario>_<pid>.log`.

| Scenario | Driver | Expects |
|---|---|---|
| `solo` | `scripts/real_claude_audit.sh` | 4 prompts (chat / base64 / long / code) all clean |
| `2eng_qa` | `scripts/real_claude_2eng_qa_e2e.sh /tmp/gtmulti` (set up the repo first, see §"Repo seeds" below) | 3 commits ahead of main, summary + PR URL |
| `consult` | `scripts/real_claude_consult_e2e.sh` | Atlas summary populated, Iris final summary populated, PR URL |
| `recovery` | Script the test-mode driver: prompt → SessionFailed → quit → relaunch → Start fresh → quit → relaunch → assert fresh state. See §"Recovery probe" below. | No leftover transcript on second relaunch |
| `worktrees` | Set `workspace_mode: worktree-per-engineer` in team.yaml, dispatch an engineer, verify `.gala_team/worktrees/<name>` exists, Start fresh, verify it's gone. | Worktrees vanished after Start fresh |
| `leak` | `scripts/live_audit2.sh` scenarios 25 + 13 + 14 + 18 | All assertions report "OK" |

If a scenario lacks a script, write one inline using `gala_team_headless` for prompt-and-capture, then run it.

### Step 3 — Inspect the captured output

For every scenario produce:

#### A. JSON-leak detection
Grep the captured conversation entries for stream-json envelope markers:
```
grep -cE '\\"stop_reason\\"|\\"session_id\\"|\\"usage\\":\\{|\\"parent_tool_use_id\\"' "$file"
```
Any match in conversation `text` fields is a HIGH-severity leak. Also flag plain `{"type":"assistant"` substrings ("$file" is JSON-encoded so leaks have escaped quotes).

#### B. UX / user-flow assessment
For each scenario walk the captured transcript and record:
- **Time-to-first-meaningful-output**: how long before the user sees any text after `you:` (best estimate from message ordering).
- **Empty turns**: any conversation entries that are `""` or just whitespace — these are bugs (a missing chunk or filter false-positive).
- **Duplicate adjacency**: two consecutive entries from the same speaker with identical text — usually means streaming + result echo BOTH rendered (currently expected per "render result.result" decision, but flag if it's annoying).
- **Speaker confusion**: any `Speaker` value that isn't a real team member (typos, unknown names) — indicates parser bug.

#### C. Quality assessment of orchestration
- **Did engineers actually commit?** Check `git log --oneline main..HEAD` in the scenario repo. Engineer @finished bodies should match real commits (hash + message).
- **Did QA actually inspect?** QA's response should mention specific files / commits / line numbers. A bare "LGTM" is a failure.
- **Did the lead's @summary cite specifics?** File paths, commit hashes, QA verdict. A summary that's all hand-wavy ("the team did the work") is a UX bug — the lead's job is to report.

#### D. Usability friction signals
- **Unwrapped permission prompts**: search the JSON output for `"permission denied"` or `"approval"` in the text. If real claude was blocked, the team config probably lacks `dangerously_skip_permissions: true`. Suggest the fix.
- **Missing onboarding**: if the lead's first response says "I don't see X" or "what is the project context", the onboarding pack didn't reach them. Suggest adding `onboarding:` paths.
- **Race-y dispatches**: if two engineers' commits touched the same lines of the same file, the parallel-engineer dispatch has a collision. Flag and recommend sequential dispatch or worktree-per-engineer.

#### E. Bug detection
For every error message in the captured logs, classify:
- **Infrastructure**: claude binary missing, gh missing, repo not initialised. Skill should suggest the fix.
- **Orchestrator**: panics in gen.go, FSM stuck in non-terminal state. File a bug entry.
- **Claude protocol**: non-zero exit code, rate limit, malformed stream-json. Note for the user but don't fail the run.

### Step 4 — Generate report

Use the template in §"Output format" below. Pin the report to a file under `/tmp/galateam_e2e_report_<pid>.md` for the user to keep.

### Step 5 — Suggest follow-ups

Based on findings, propose specific actions. Never just say "look into it" — write the exact `git diff` shape, the exact CLI command, or the exact line of code to change. If JSON leaks are found, point at `app/ui/update.gala::sanitizeAssistantText` and `app/headless/headless.gala::ExtractClaudeText` since those are the two places filtering happens.

---

## Repo seeds

The 2eng_qa scenario expects a repo at the path you pass it. To set up `/tmp/gtmulti`:

```bash
rm -rf /tmp/gtmulti && mkdir -p /tmp/gtmulti && cd /tmp/gtmulti
git init -q -b main
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
cat > calc.go <<'EOF'
package main

import "fmt"

func add(a, b int) int { return a + b }
func mul(a, b int) int { return a * b }

func main() { fmt.Println(add(2, 3)); fmt.Println(mul(4, 5)) }
EOF
git -c user.email=t@t -c user.name=t add calc.go
git -c user.email=t@t -c user.name=t commit -q -m "add calc.go"
cp $REPO_ROOT/scripts/seed_team_2eng_qa.yaml team.yaml || cat > team.yaml <<'EOF'
teams:
  - key: main
    name: "Skunkworks"
    dangerously_skip_permissions: true
    members:
      - role: team_lead
        name: "Iris"
        personality: "Decides quickly, dispatches in parallel."
      - role: engineer
        name: "Felix"
        personality: "Implements add() changes."
      - role: engineer
        name: "Mira"
        personality: "Implements mul() changes."
      - role: qa
        name: "Theo"
        personality: "Reviews engineer commits."
workflow:
  qa_required: true
EOF
git checkout -b feat/calc-guards
git update-ref refs/heads/main HEAD~1
```

The consult scenario builds its own repos inside `$OUT` and does not need pre-seed.

## Recovery probe

To verify the recovery / Start-fresh / leftover-data path:

```bash
SBX="/tmp/gtrecover_$$"
mkdir -p "$SBX" && cd "$SBX"
git init -q -b main
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
cp examples/minimal.yaml team.yaml

BIN="$(bazel info bazel-bin)/cmd/gala_team_/gala_team.exe"

# First run: type something + force-quit (no clean shutdown).
echo '{"type":"key","char":"h"}
{"type":"key","char":"i"}
{"type":"key","key":"Enter"}
{"type":"msg","name":"ChunkArrived","member":"Lead","line":"hello back"}
{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}
{"type":"quit"}' | "$BIN" --test-mode --team "$SBX/team.yaml" --project "$SBX" > /dev/null

# Second run: should show recovery modal, then Start fresh.
echo '{"type":"snapshot","detail":"plain"}
{"type":"key","key":"Tab"}
{"type":"key","key":"Tab"}
{"type":"key","key":"Enter"}
{"type":"snapshot","detail":"plain"}
{"type":"quit"}' | "$BIN" --test-mode --team "$SBX/team.yaml" --project "$SBX" > "$SBX/run2.jsonl"

# Third run: verify NO leftover data.
echo '{"type":"snapshot","detail":"plain"}
{"type":"quit"}' | "$BIN" --test-mode --team "$SBX/team.yaml" --project "$SBX" > "$SBX/run3.jsonl"

LEFTOVER=$(grep -c "hello back" "$SBX/run3.jsonl" || true)
case "$LEFTOVER" in
  0) echo "  -> recovery clean: no leftover after Start fresh";;
  *) echo "  !! BUG: 'hello back' still visible after Start fresh — see $SBX/run3.jsonl";;
esac
```

## Output format

```markdown
# gala_team E2E report

**Repo:** $REPO_ROOT
**Binary:** bazel-bin/cmd/gala_team_/gala_team.exe (mtime: …)
**Scenarios run:** solo, 2eng_qa, consult, recovery, leak
**Total wall time:** XX min

## Scenario results

| Scenario | Status | Wall time | Captured at |
|---|---|---|---|
| solo | ✓ pass | 32s | /tmp/galateam_skill_solo_… |
| 2eng_qa | ✓ pass | 4m12s | … |
| consult | ⚠ partial | 2m04s | … |
| recovery | ✓ pass | 18s | … |

## Findings (severity-ordered)

### HIGH — JSON leaks
(none, or list with line numbers)

### HIGH — Orchestrator bugs
(none, or per-scenario reproduction)

### MED — UX friction
- Empty turns observed in consult/02_atlas: Atlas's first stream chunk was 0 bytes; the assistant block carried only `tool_use`. Suggest …
- Duplicate adjacency: 2eng_qa Felix line 3 and 4 are identical (streamed + result echo). Acceptable per current design but consider dedup.

### LOW — Usability
- 2eng_qa: lead's @summary doesn't cite line numbers, only file paths. Onboarding could nudge "cite line numbers for code review".

## Suggested follow-ups (each with exact action)
1. `app/ui/update.gala:2189` — extend `truncateAtEnvelopeMarker` markers list to include `"api_error_status":` (seen in scenario X).
2. team.yaml `dangerously_skip_permissions: true` is required for E2E; add a CLI warning when it's missing in the scenario harness.
3. …
```

## After running

1. Save the report to `/tmp/galateam_e2e_report_<pid>.md`.
2. Print it to the user with the suggested follow-ups highlighted.
3. Ask: "Want me to apply any of the suggested fixes?" — only proceed when the user confirms.
