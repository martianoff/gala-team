---
description: Design a new gala_team `team.yaml` from scratch, or optimize an existing one, for a given project / area. Reads the target project's structure (README, CLAUDE.md, language, test commands, repo conventions) and produces a concrete team config with roles, personalities, onboarding docs, workflow, and policy tuned to the project. TRIGGER when the user asks to "design a team", "create a team for X", "optimize my team.yaml", "review my gala team", "team for <project>", or similar.
user-invocable: true
---

# gala_team designer

Produce a `team.yaml` (or a focused diff against an existing one) tuned to the user's project. The output is a concrete, ready-to-run config — no placeholders, no "TODO" comments — based on what the project actually looks like.

**Argument:** `$ARGUMENTS` — Either:
- A path to a project directory (e.g. `~/work/auth-service`) → design a team from scratch for it.
- A path to an existing `team.yaml` (e.g. `team.yaml`, `examples/skunkworks.yaml`) → review and propose optimizations.
- A short project description (e.g. `"a Rust web crawler with sqlite storage"`) → design a team without a target repo.
- Empty → ask the user which mode and what target.

## Output contract

The skill MUST end with one of:
1. **A complete `team.yaml`** in a fenced ```yaml block, ready for `gala_team --team <path> --project <repo>`. No placeholders, no `<TODO>` markers.
2. **A focused diff** against an existing `team.yaml` (paths to read/edit + concrete replacement blocks), if optimizing.

Plus a brief rationale (~5-8 bullets) explaining the key choices: roster size, why or why not QA, workspace_mode pick, hook commands picked, what each member's personality is tuned for. Rationale is for the user; the yaml is for the machine.

---

## Step 1 — Survey the target

When given a project path:

1. Read `README.md` (or equivalent) for project purpose + commands. Skim, don't summarize back.
2. Read `CLAUDE.md` if present — it's the highest-signal source on conventions, gotchas, and forbidden patterns. CLAUDE.md belongs in **team-wide `onboarding:`** (so every member reads it on first prompt). Do NOT also restate its rules in `extra_instructions` — that's duplication; the model already has the file in context.
3. Detect the language(s) and build system:
   - Look for `go.mod`, `Cargo.toml`, `package.json`, `pyproject.toml`, `pom.xml`, `BUILD.bazel`, `Makefile`, etc.
   - Run the file lookup with Glob — don't guess.
4. Detect the test command. Common shapes:
   - Go: `go test ./...` or `bazel test //...`
   - Rust: `cargo test`
   - Node: `npm test` or `yarn test`
   - Python: `pytest` or `python -m unittest`
   - Bazel-driven: `bazel test //...`
5. Detect the lint/vet command. `go vet ./...`, `cargo clippy -- -D warnings`, `eslint .`, `ruff check`, `mypy`, etc.
6. Look for existing CI in `.github/workflows/*.yml` — the commands run there are the user's source of truth for what counts as "passing".
7. Skim a couple of representative source files (~3-5) to gauge style. Functional vs imperative? Tests in same file or separate? Docstrings or terse?

When given a project description (no path):
- Skip steps 1, 2, 3, 6, 7. Use steps 4–5 from general knowledge of the language.

When given an existing `team.yaml`:
- Read it. Read the project root it was designed for (if discoverable from `--project` defaults or README). Then proceed to step 2.

## Step 2 — Pick the roster

The cost model: each member is one claude session per turn. Two engineers is twice the API spend per dispatch. QA adds a serial step that the FSM gates on. Optimize for the smallest roster that does the job.

**Always**:
- Exactly one `team_lead`. The user types only to the lead; the lead delegates.

**Engineers** — pick from:
- **1 engineer** for: small features (single file, single concept), prototyping, exploration tasks, code review, single-language refactors. Default for unknown projects.
- **2 engineers** for: tasks that decompose into clearly orthogonal pieces (e.g. parser + validator, frontend + API, two unrelated bug fixes). The lead must be able to write a `@dispatch(A) ... @end @dispatch(B) ... @end` pair where A and B don't touch the same files.
- **3+ engineers** rarely. Beyond 3, the lead's ability to write non-overlapping briefs degrades. Prefer sequential turns over wider parallelism.

Avoid identical-personality engineers. If you need two of the same shape, you usually need one (do it twice) or two distinct shapes (e.g. one TDD-first, one explorer-first).

**QA** — include when:
- The project ships to users (production library, service).
- The project has a test suite the engineers run themselves but a second pair of eyes is needed.
- Code-style enforcement matters (CLAUDE.md says "must use X pattern", or there's a strict lint config).

Skip QA when:
- The project is a prototype / spike.
- The user explicitly said "single-engineer team" or "no QA".
- The target is documentation / config / non-code work.

If unsure, include QA — the FSM gates on it cleanly and the user can disable via `qa_required: false` later.

## Step 3 — Personalities and extra_instructions

A member's `personality` is one paragraph (2-4 lines) describing their *voice and decision style*. NOT their job description — the role already does that. Examples that work:

```yaml
personality: "Functional-leaning, terse. Explains tradeoffs in two lines max."
personality: "Pragmatic. Hates premature abstraction. Reaches for the boring solution."
personality: "Evidence-driven. Reproduces every reported bug before opining."
personality: "Calm, decisive. Asks one clarifying question before delegating."
```

Examples that DON'T work (too vague / too vibes-y / too prescriptive):

```yaml
personality: "Senior engineer with 10 years of experience"   # no behavioral signal
personality: "Smart and helpful"                              # vacuous
personality: "Always uses the strategy pattern"               # coding convention — belongs in CLAUDE.md / onboarding, not personality
```

### What the orchestrator already injects — DO NOT restate in `extra_instructions`

The orchestrator builds every member's first prompt by stitching together (1) the role section it generates internally, (2) the team-wide and per-member `onboarding:` files, and (3) the user's task. Anything inside (1) or (2) is already in the model's context — restating it in `extra_instructions` is pure duplication. It bloats the prompt, fights the source of truth in `app/onboarding/onboarding.gala` + `app/ui/update.gala::buildQAReviewPrompt`, and changes nothing in behavior.

What the **TL prompt** already injects (`onboarding.gala::protocolSection`, isTL branch):
- Directive vocabulary (`@dispatch`, `@consult`, `@summary`, `@end`) with a worked two-engineers-in-parallel example.
- The full `@summary` PR-shape rules: `## What` / `## Why` / `## Follow-ups`, "no member names / no orchestration internals", "if you can't ship, don't `@summary`".
- A worked `@summary` example body.
- Cross-team consult etiquette (when the first prompt this turn arrived via `@consult`).
- "Don't fabricate names — only dispatch to members listed in `# Your team`".
- "What does NOT dispatch" (decorative arrows, multi-target syntax, markdown headings).
- TL workspace layout: lead branch, `_lead/` worktree, "main repo OFF LIMITS", PR snapshot mechanics, "multiple PRs from one workspace coexist".

What the **engineer / QA prompt** already injects (`onboarding.gala::protocolSection`, !isTL branch):
- `@finished` / `@help` / `@blocked` vocabulary, "exactly one terminal directive per turn".
- Member workspace layout: own cwd, own branch, "list files you wrote in `@finished`".
- The "commit before `@finished`" requirement and the exact `git add -A && git commit` recipe.

What the **QA review prompt** already injects (`update.gala::buildQAReviewPrompt`, sent at every QA turn):
- A pre-aggregated **deliverable manifest**: each engineer's cwd + branch + changed files (with `C` / `M` / `?` prefixes).
- Verdict format: open with `Recommendation: re-dispatch <Member>` / `Recommendation: TL acts directly` / `Recommendation: escalate to user`.
- "Cite EXACT branch refs from the manifest above" (with the `gala_team/<proj>/<member>` pattern).
- "Cite absolute file paths" (the worktree paths from the manifest).
- The required `Files reviewed: ...` closing line.
- The full `@finished` / `@blocked` sign-off protocol.

What the **onboarding files** already inject (whatever you list under `onboarding:`):
- Full text of `CLAUDE.md`, `GALA_BEST_PRACTICES.md`, `ARCHITECTURE.md`, etc.
- Coding conventions, forbidden patterns, required practices, project-specific tooling, hard rules — **all of these belong in onboarding files**, not pasted into `extra_instructions`. If a rule isn't already documented in the project, add it to `CLAUDE.md` or a new doc and onboard on it; don't paper over the gap by inlining it on the team config.

### What `extra_instructions` IS for

Use it only for things the orchestrator's built-ins and onboarding can't supply:

- **TL: zone-of-focus routing.** The TL's roster section lists members + first-line personalities, but it doesn't tell the TL where each engineer DEFAULTS. A 2+ engineer team benefits from "Felix → frontend, Mira → API" routing the TL otherwise has to re-derive every turn.
- **TL: multi-team scope.** In a multi-team setup, what THIS team owns vs siblings (e.g. "this team handles `auth/`, sibling `data` team handles `ingest/`"). The cross-team consult etiquette is built-in; the team-vs-team scope boundary is config knowledge.
- **Engineer: zone echo.** A one-line reminder of the engineer's own default focus, so they don't drift cross-cutting on every brief.
- **QA: usually empty.** Onboarding + the QA review prompt already cover the role almost completely. Leave it blank unless there's a verdict-shaping concern that isn't already in CLAUDE.md and isn't already in the built-in QA prompt.

Two quick smell tests for any line you're tempted to add:
- Is this line specific to *this team's roster / decomposition*? If yes, keep it. If it would apply equally to any team running the same project, it belongs in `CLAUDE.md` / onboarding.
- Could this line be invalidated by a future change to `app/onboarding/onboarding.gala` or `app/ui/update.gala`? If yes, it's restating a built-in — drop it.

If you find yourself writing "must use functional patterns", "always cite branch refs", "open with Recommendation:", or "@summary must be PR-shaped" — stop. The first belongs in the project's `CLAUDE.md`; the rest are already injected by the orchestrator.

### Personalities — keep distinct

Make personalities **distinct across members**. Two engineers with the same voice produce indistinguishable transcripts and waste a slot.

## Step 4 — Workflow

```yaml
workflow:
  qa_required: true | false              # match Step 2's QA decision
  parallel_engineers: true               # default true, almost always correct
  approval:
    require_user_confirm: true           # default true; rarely useful to disable
```

Override these only with a stated reason. `parallel_engineers: false` is for very specific serial-dependency workflows; `require_user_confirm: false` is for headless automation, not interactive use.

## Step 5 — Policy

```yaml
policy:
  workspace_mode: shared | worktree-per-engineer
  merge_rule: squash | rebase | merge
  pre_merge:
    - name: <human-readable>
      cmd: <executable>
      args:
        - <arg1>
        - <arg2>
  post_merge:
    - name: ...
```

**workspace_mode** — DEFAULT to `worktree-per-engineer`. Only emit `shared` when the user has explicitly asked for it.

The reasoning: shared mode loses on basically every dimension that matters for orchestrated work (engineers can trample each other's working tree, QA can't reliably tell who wrote which line, the per-engineer branch namespace doesn't get used). It exists for solo / read-only / prototype-only setups; it's not the right starting point for any team that's going to commit code.

- `worktree-per-engineer` *(default — emit unless user said otherwise)* — each engineer gets `<repo>/.gala_team/worktrees/<name>` on their own branch. Required for: 2+ engineers in parallel, anything that involves committing, anything with `qa_required: true` (QA reviews per-engineer branches). Required, also, for any project where you want clean per-engineer git history.
- `shared` *(only when explicitly asked)* — engineers/QAs run in the project root. Simpler, fastest. Fine for 1-engineer prototyping where the user has said they want it.

The TL **always** runs in its own `_lead/` worktree regardless of mode (the orchestrator enforces this). `workspace_mode` only controls engineer/QA isolation.

**dangerously_skip_permissions** — DEFAULT to `true`. Only emit `false` when the user has explicitly asked for it.

```yaml
teams:
  - key: main
    name: ...
    dangerously_skip_permissions: true  # default unless user asks for false
    ...
```

The reasoning: gala_team is an orchestrator the user has already opted into. Engineers running with `--dangerously-skip-permissions` skip claude's per-tool approval prompts that would otherwise pause the orchestration on every Edit / Write / Bash. Without it, a 4-member team can produce dozens of approval prompts per turn — the user spends more time clicking "Allow" than reading deliverables, and the orchestrator's parallel fanout serializes against the user's wrist. The user has approved the orchestrator's existence; they don't need to re-approve every file write inside it.

The flag is per-team (cross-team consults must opt in separately), so this isn't a blanket "trust everything" — it's "trust this team's claude session to do the file edits its dispatch body asked it to do".

**Only emit `dangerously_skip_permissions: false`** when:
- The user explicitly asked for `false` / for permission prompts.
- The team is operating on a sensitive repo where every edit warrants a human-in-the-loop check (the user will say so).

Don't emit `false` because of generic "safety" instincts. The whole point of gala_team is that the orchestrator + the lead's review + QA + the user's Approval modal are the safety layers; per-tool prompts on top of all that just slow the system down.

**merge_rule**:
- `squash` — default for most projects. One PR = one commit on the target branch.
- `rebase` — if the project has a linear-history convention enforced by CI.
- `merge` — only if the project explicitly wants merge commits (uncommon).

**pre_merge hooks** — block `gh pr create` until each succeeds. Use the actual project commands, not stubs:
- Read CI from `.github/workflows/*.yml` and pick the same lint + test commands.
- If the project uses Bazel, prefer `bazel test //...` over native test runners.
- If there's no CI to copy, use the most idiomatic command for the language (Go: `go vet ./...` + `go test ./...`; Rust: `cargo clippy -- -D warnings` + `cargo test`).
- Don't include hooks that take >2 minutes (CI is the place for slow tests).

**post_merge** — usually `[]`. Only include if the user has a real notify / deploy script. Empty list: omit the key entirely (gala's yaml decoder doesn't accept `args: []`).

## Step 6 — Onboarding docs

`onboarding:` lists relative paths from `--project`. Each path's contents are sent to the member's first prompt as context.

**Team-wide onboarding** (under the team, not under a member): docs every member needs.
- `README.md` is usually NOT a good fit — too generic, too marketing-shaped.
- Better: `CONTRIBUTING.md`, `ARCHITECTURE.md`, `docs/STYLE.md`, the repo's own `CLAUDE.md` (this is gold for behavior-shaping).

**Per-member onboarding**: docs only that role needs.
- Lead: `docs/lead-handbook.md`, design docs, the project's PR template.
- Engineers: language-specific best-practices doc, the test-writing guide.
- QA: the test runner's README, the bug-reproduction template.

Only include docs that exist. Don't list a path that's aspirational — that produces a load failure on first launch.

## Step 7 — Validate

Before emitting the final yaml, sanity-check:

- [ ] Exactly one `team_lead`.
- [ ] At least one `engineer`.
- [ ] All names are unique.
- [ ] All `onboarding:` paths exist (if you have a target project to check against).
- [ ] All `pre_merge` / `post_merge` `cmd` values resolve (Go installed for `go test`, Bazel for `bazel test`, etc.).
- [ ] If `qa_required: true`, at least one `qa` member is in `members`.
- [ ] No `args: []` (use omit-key form for empty arg lists).
- [ ] No tab characters anywhere in the yaml (gala's decoder is strict).
- [ ] `workspace_mode` matches the team size (multi-engineer → `worktree-per-engineer`).
- [ ] No personal usernames, absolute home paths, or other private artifacts in any string field.
- [ ] **No `extra_instructions` line duplicates the orchestrator's built-in injections.** Re-read every `extra_instructions` block and ask: "is this already in the TL prompt / engineer prompt / QA review prompt / onboarding files?" If yes, strip it. The remaining content should be zone-of-focus routing (lead) + own-zone echo (engineers) + usually-empty (QA).

If any check fails, fix before emitting.

---

## Optimization mode (existing team.yaml)

When the input is an existing `team.yaml`, do step 1 (survey project) then a SECOND pass on the existing config:

**Common smells to flag and fix**:
- **Vague personalities** — "smart engineer" / "10 years experience". Rewrite as voice + decision style.
- **Identical personalities** across engineers. Differentiate or drop one.
- **QA enabled but no QA member** (or vice versa) — yaml validates but FSM stalls on QAGate forever.
- **`workspace_mode: shared` without a stated reason** — `worktree-per-engineer` is the default. Shared mode with 2+ engineers is almost always a bug (they trample each other); shared mode with 1 engineer is fine if the user picked it deliberately, but if there's no comment / extra_instructions explaining why, propose flipping to worktree.
- **`dangerously_skip_permissions: false` (or absent) without a stated reason** — `true` is the default. Without it, every Edit / Write / Bash from any member opens an approval prompt; the orchestrator's parallel fanout serializes against the user's wrist. Propose flipping to true unless the team's notes say "permission prompts are required because <reason>".
- **`pre_merge` hooks that don't match CI** — engineer ships work that passes locally but CI rejects. Sync them.
- **No team-wide onboarding when CLAUDE.md exists** — the project's own conventions are invisible to the team.
- **5+ members** — usually means the lead can't write distinct briefs. Suggest consolidating or splitting into multi-team.
- **`extra_instructions` duplicates orchestrator built-ins.** The most common smell. Look for:
  - Lead `extra_instructions` restating `@summary` PR-shape rules (`## What` / `## Why` / `## Follow-ups`, "no internal nuance", "no orchestration internals") or the parallel-dispatch example — all already in `app/onboarding/onboarding.gala::protocolSection`.
  - QA `extra_instructions` restating "open with `Recommendation:`", "cite branch refs", "cite absolute file paths" — all already in `app/ui/update.gala::buildQAReviewPrompt`.
  - Engineer `extra_instructions` restating coding conventions / forbidden patterns / hard rules from the project's `CLAUDE.md` — those are already loaded once via team-wide `onboarding:`.

  Strip these. What's left should be zone-of-focus routing on the lead, an own-zone echo on each engineer, and (almost always) empty for QA.

- **Missing zone-of-focus routing on a 2+ engineer team's lead** — the TL's roster section lists members but doesn't say where each defaults. Without routing, the lead has to invent decomposition every turn. Add a short "Felix → X, Mira → Y" block to the lead's `extra_instructions` (and a one-line echo on each engineer).

Produce a focused diff: list each change with its rationale. Don't rewrite the whole file when 3 fields need changes.

---

## Worked example (don't blindly emit this — adapt)

Project: small Go service with a Bazel build, has `CLAUDE.md` saying "use functional patterns over imperative", CI runs `go vet` + `go test`. ~5kloc.

```yaml
teams:
  - key: main
    name: "Authy"
    description: "Auth-service maintainers"
    dangerously_skip_permissions: true
    onboarding:
      - CLAUDE.md
      - docs/ARCHITECTURE.md
    members:
      - role: team_lead
        name: "Lin"
        personality: |
          Decisive, asks one clarifying question max before dispatching.
          Always closes a turn with @summary or returns to the user with a
          specific next step — never trails off.
        extra_instructions: |
          Zone-of-focus when picking who to dispatch:
            Quinn → auth flow (handlers, middleware, OAuth provider glue)
            Sage  → storage (DB schema, queries, migrations)
          Cross-over allowed when the work demands it; bias to defaults
          when both engineers fit equally.
      - role: engineer
        name: "Quinn"
        personality: |
          Functional-leaning, terse. States invariants before code.
        extra_instructions: |
          Default focus: auth flow — handlers, middleware, OAuth glue.
          Cross over to storage only when the work demands it.
      - role: engineer
        name: "Sage"
        personality: |
          Pragmatic. Reaches for the boring solution. Writes tests first.
        extra_instructions: |
          Default focus: storage — DB schema, queries, migrations.
          Cross over to handlers only when the work demands it.
      - role: qa
        name: "River"
        personality: |
          Evidence-driven. Reproduces bugs in a test before opining.

workflow:
  qa_required: true
  parallel_engineers: true
  approval:
    require_user_confirm: true

policy:
  workspace_mode: worktree-per-engineer
  merge_rule: squash
  pre_merge:
    - name: vet
      cmd: bazel
      args:
        - run
        - "@io_bazel_rules_go//go:go"
        - --
        - vet
        - ./...
    - name: test
      cmd: bazel
      args:
        - test
        - //...
```

The rationale that should accompany it:

- 2 engineers because Authy's typical features (e.g. "add OAuth provider X") split into auth-flow + storage. 1 would queue them serially; 3 would force the lead to invent fake decomposition.
- QA included because production auth code. River's `extra_instructions` is empty: the built-in QA review prompt already injects the verdict format (Recommendation type, branch refs from the manifest, absolute file paths, `Files reviewed:` line), and onboarding carries the project rules — there's nothing config-specific to add.
- `dangerously_skip_permissions: true` — the default. The orchestrator + lead review + QA + the Approval modal are the safety layers; per-tool prompts on top of those would just stall every dispatch on the user's wrist.
- `worktree-per-engineer` — the default, required anyway by 2 engineers + QA reviewing committed work.
- Hooks pulled from CI — the actual `bazel test //...` command, not a stubbed `go test`.
- Onboarding includes CLAUDE.md so the team's CLAUDE-style rules (functional, no `any`) reach every member without being restated per-role.
- Lin's `extra_instructions` is just zone-of-focus routing. The `@summary` PR-shape rules and the parallel-dispatch example are already injected by the orchestrator's built-in TL prompt; restating them would only duplicate what the model sees on first prompt.
- Quinn's and Sage's `extra_instructions` echo their default zone in one line each — the TL has the routing, the engineers have the matching default. Coding conventions (pattern matching, immutability, test-first) are NOT restated here; CLAUDE.md in onboarding covers them.

---

## Anti-patterns to never produce

- **Generic team.yaml.** A team that could ship for any project is too vague to ship for any specific one. Always name conventions, commands, and rules from the survey step.
- **Placeholders in the output.** `# TODO: pick a name`, `<your project>`, `cmd: <test command>` — never. If the survey didn't reveal the answer, ask the user once before emitting; don't ship a half-config.
- **Copying skunkworks.yaml verbatim.** It's an example, not a template. Names, personalities, hooks all need to be project-specific.
- **Recommending more parallelism than the project supports.** A 5-file repo doesn't benefit from 3 engineers.
- **Hooks that don't exist** (`go test ./...` in a Rust repo). Always validate that `cmd` is something the project actually uses.
