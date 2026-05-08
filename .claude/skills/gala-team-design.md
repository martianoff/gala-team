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
2. Read `CLAUDE.md` if present — it's the highest-signal source on conventions, gotchas, and forbidden patterns. Anything in CLAUDE.md MUST flow through into the team's `extra_instructions` or per-role onboarding.
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
personality: "Always uses the strategy pattern"               # belongs in extra_instructions
```

`extra_instructions` carries project-specific rules the personality doesn't capture:
- Coding conventions ("default to pattern matching over if-else")
- Forbidden patterns ("never use `any`/`interface{}` — fail with an error if type can't be inferred")
- Required practices ("write the test before the implementation")
- Project-specific tools ("use `bazel test //crypto:crypto_test` not `go test`")
- Anything from the project's CLAUDE.md that applies to the member's role

Lead's extra_instructions specifically should cover:
- When to dispatch in parallel vs sequence
- When to @consult a sibling team (only if multi-team)
- @summary discipline ("PR description, not chat recap; ## What / ## Why / ## Follow-ups")

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

**workspace_mode**:
- `shared` — engineers/QAs run in the project root. Simpler, fastest. Fine for 1-engineer teams or read-only tasks.
- `worktree-per-engineer` — each engineer gets `<repo>/.gala_team/worktrees/<name>` on their own branch. Required for: 2+ engineers in parallel, anything that involves committing, anything with `qa_required: true` (QA reviews per-engineer branches).

The TL **always** runs in its own `_lead/` worktree regardless of mode (the orchestrator enforces this). `workspace_mode` only controls engineer/QA isolation.

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

If any check fails, fix before emitting.

---

## Optimization mode (existing team.yaml)

When the input is an existing `team.yaml`, do step 1 (survey project) then a SECOND pass on the existing config:

**Common smells to flag and fix**:
- **Vague personalities** — "smart engineer" / "10 years experience". Rewrite as voice + decision style.
- **Identical personalities** across engineers. Differentiate or drop one.
- **QA enabled but no QA member** (or vice versa) — yaml validates but FSM stalls on QAGate forever.
- **`workspace_mode: shared` with 2+ engineers** — likely a bug; they'll trample each other's working tree. Switch to `worktree-per-engineer`.
- **`pre_merge` hooks that don't match CI** — engineer ships work that passes locally but CI rejects. Sync them.
- **No team-wide onboarding when CLAUDE.md exists** — the project's own conventions are invisible to the team.
- **5+ members** — usually means the lead can't write distinct briefs. Suggest consolidating or splitting into multi-team.
- **Missing `extra_instructions` on the lead** — leads default to generic "decompose and dispatch" without project-specific guidance, producing low-quality @dispatch bodies.

Produce a focused diff: list each change with its rationale. Don't rewrite the whole file when 3 fields need changes.

---

## Worked example (don't blindly emit this — adapt)

Project: small Go service with a Bazel build, has `CLAUDE.md` saying "use functional patterns over imperative", CI runs `go vet` + `go test`. ~5kloc.

```yaml
teams:
  - key: main
    name: "Authy"
    description: "Auth-service maintainers"
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
          Prefer one engineer for single-file changes; two for orthogonal
          tasks (auth flow vs storage layer).
          @summary body must be PR-shaped: ## What / ## Why / ## Follow-ups.
          Never paste internal paths or bookkeeping into @summary.
      - role: engineer
        name: "Quinn"
        personality: |
          Functional-leaning, terse. States invariants before code.
        extra_instructions: |
          Default to pattern matching and small pure functions per the
          repo's CLAUDE.md; avoid mutable state outside func bodies.
      - role: engineer
        name: "Sage"
        personality: |
          Pragmatic. Reaches for the boring solution. Writes tests first.
        extra_instructions: |
          Cover happy path + 1-2 edge cases per change. Never ship without
          a passing test for the new behavior.
      - role: qa
        name: "River"
        personality: |
          Evidence-driven. Reproduces bugs in a test before opining.
        extra_instructions: |
          Verdicts cite EXACT branch refs (gala_team/<proj>/<member>) and
          ABSOLUTE file paths from the manifest, not member names alone.
          Open with: Recommendation: re-dispatch / TL acts directly /
          escalate to user.

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
- QA included because production auth code; River's verdict format mirrors the orchestrator's QA-prompt expectations (cite refs, open with recommendation).
- `worktree-per-engineer` — required by 2 engineers + QA reviewing committed work.
- Hooks pulled from CI — the actual `bazel test //...` command, not a stubbed `go test`.
- Onboarding includes CLAUDE.md so the team's CLAUDE-style rules (functional, no `any`) flow into every member.
- Lin's `extra_instructions` repeats the @summary rules because past sessions have shown TLs slipping into chat-recap PRs without it.

---

## Anti-patterns to never produce

- **Generic team.yaml.** A team that could ship for any project is too vague to ship for any specific one. Always name conventions, commands, and rules from the survey step.
- **Placeholders in the output.** `# TODO: pick a name`, `<your project>`, `cmd: <test command>` — never. If the survey didn't reveal the answer, ask the user once before emitting; don't ship a half-config.
- **Copying skunkworks.yaml verbatim.** It's an example, not a template. Names, personalities, hooks all need to be project-specific.
- **Recommending more parallelism than the project supports.** A 5-file repo doesn't benefit from 3 engineers.
- **Hooks that don't exist** (`go test ./...` in a Rust repo). Always validate that `cmd` is something the project actually uses.
