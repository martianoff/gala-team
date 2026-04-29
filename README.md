# gala_team

A terminal orchestrator that turns a team of Claude CLI sessions into a single
chain-of-command. You talk to the **Team Lead**. The Team Lead delegates to
**Engineers** and **QAs**, reviews their work, and hands you back a summary and
a pull request for sign-off.

Written in [GALA](https://github.com/martianoff/gala) with the
[`gala_tui`](https://github.com/martianoff/gala_tui) Elm-style TUI framework.

> Status: alpha. Schema and key bindings may shift between commits.

---

## What it does

```
┌─────────────────────────────────────────────────────────────┐
│ ⛩  gala_team    state: TL thinking    tick: 47              │
│   Skunkworks  ·  Default product team                       │
├──── Team ────────┬──── Conversation with Team Lead ────────┤
│ ▼ Lead           │ you: ship the new /metrics endpoint      │
│   ⠋ Iris         │ Iris: dispatching to Felix…              │
│ ▼ Engineering    │ Felix: implementing handler + tests…     │
│   ⠼ Felix        │ Theo: reviewing for missing edge cases…  │
│ ▼ QA             │ Iris: ▶ Ready to ship: feat(api): add …  │
│   ⠦ Theo         │       Ctrl+A approve & open PR · Ctrl+R │
├──────────────────┴──────────────────────────────────────────┤
│ Type to Iris…                                               │
└─────────────────────────────────────────────────────────────┘
  Enter send · Backspace · Ctrl+A approve · Ctrl+R reject ·
  Tab consults · Ctrl+H history · Ctrl+C quit
```

A user prompt enters the **Team Lead**'s conversation. The Team Lead can
emit orchestration directives in its assistant text:

| Directive | Effect |
|-----------|--------|
| `@dispatch(<member>) … @end` | Hand a task to a teammate (Engineer / QA). |
| `@consult(<key>) … @end` | Ask another team (in-project sibling or cross-repo). |
| `@summary … @end` | Final answer + PR body. Triggers approval mode. |

---

## Install

You need:

- [Bazelisk](https://github.com/bazelbuild/bazelisk) (a wrapper around `bazel`)
- Go 1.25+ (Bazel will use the SDK declared in `MODULE.bazel`)
- `claude` CLI on `PATH` (this is what gala_team spawns)
- `gh` CLI on `PATH` (for `gh pr create` / `gh pr merge`)
- A clone of [`martianoff/gala`](https://github.com/martianoff/gala) and
  [`martianoff/gala_tui`](https://github.com/martianoff/gala_tui) as siblings of
  this repo, or the modules pinned in `MODULE.bazel`.

Build:

```bash
bazel build //cmd:gala_team
```

The binary lands at `bazel-bin/cmd/gala_team_/gala_team`.

---

## Quickstart

1. **Define your team** in `team.yaml` at the project root. Smallest viable file:

   ```yaml
   teams:
     - key: main
       name: Skunkworks
       description: Default product team
       members:
         - role: team_lead
           name: Iris
           personality: Calm, decisive. Asks for evidence.
         - role: engineer
           name: Felix
           personality: Functional-leaning, terse.
         - role: qa
           name: Theo
           personality: Evidence-driven. Asks for tests.
   workflow:
     qa_required: true
   ```

2. **Run** in your project directory:

   ```bash
   gala_team --project . --team team.yaml
   ```

3. **Type a prompt**, press `Enter`. Watch the team work.

4. When the lead emits `@summary`, the banner switches to **approval mode**.
   Press `Ctrl+A` to fire `gh pr create`, then `Ctrl+M` to merge.

---

## team.yaml schema (full reference)

Every field, with defaults and acceptable values. Anything not listed here is
ignored by the parser.

```yaml
# ─── teams ────────────────────────────────────────────────────────────────
# Required. List of one or more teams. The first entry is the "main" team
# unless --team-key picks another. Sibling entries are addressable from the
# main team's lead via @consult(<key>).
#
# Backwards-compat: the legacy `team:` (singular) block at top level is
# still accepted and lowered to a one-entry teams list with key="main".

teams:
  - key: main                       # required if multi-team. Used by @consult / --team-key.
                                    # Falls back to a slug of `name` when omitted.
                                    # Must be unique across the teams list.
    name: "Skunkworks"              # required. Display name shown in the TUI header.
    description: "Product team"     # optional. One-line subtitle shown next to `name`.

    dangerously_skip_permissions: false   # optional. Default false. When true, every
                                    # spawned `claude` for this team is invoked with
                                    # `--dangerously-skip-permissions`. Use ONLY when
                                    # you've already granted the parent permissions
                                    # and want sub-agents to inherit them without
                                    # re-prompting. Each team is a separate decision
                                    # — a sibling consult team's flag is independent.

    onboarding:                     # optional. List of file paths (relative to --project,
      - docs/CONTRIBUTING.md        # absolute paths also accepted) read once and prepended
      - docs/ARCHITECTURE.md        # to every member's first prompt. Subsequent prompts
                                    # don't re-send.

    members:                        # required. ≥1 entry; exactly one role: team_lead;
                                    # ≥1 role: engineer; role: qa needed when
                                    # workflow.qa_required is true.
      - role: team_lead             # required. one of: team_lead | engineer | qa
        name: "Iris"                # required. Unique within the team.
        personality: |              # optional. Free-form text fed into the system prompt.
          Calm, decisive. Asks clarifying questions before delegating.
        model: claude-opus-4-7      # optional. Pins the Claude model. Omit to use claude-cli's
                                    # default. Passed as `--model <name>` to claude.
        extra_instructions: |       # optional. Appended to the member's system prompt
          Always cite line numbers.  # below the personality block. Free-form text.
        onboarding:                 # optional. Per-member paths, in addition to the
          - docs/lead-handbook.md   # team-wide onboarding above.

      - role: engineer
        name: "Felix"
        personality: "Terse, functional-leaning."

      - role: qa
        name: "Theo"
        personality: "Evidence-driven."

  # Sibling team — addressable as @consult(transpiler) from `main`'s lead.
  - key: transpiler
    name: "Transpiler Wizards"
    description: "Compiler / language work"
    members:
      - role: team_lead
        name: "Theo"
        personality: "Precise. Cites specs."
      - role: engineer
        name: "Cade"
        personality: "Pragmatic."

# ─── workflow ─────────────────────────────────────────────────────────────
# How a team operates internally. All keys optional; defaults shown.
workflow:
  qa_required: true                 # default true. When true, every team must declare ≥1
                                    # qa member; the orchestration FSM gates approval on
                                    # QADone. Set false for engineer-only teams.
  parallel_engineers: true          # default true. When true, multiple @dispatch directives
                                    # in one TL message run engineers concurrently. When
                                    # false, the FSM serialises them one at a time.
  approval:
    require_user_confirm: true      # default true. Final @summary opens the Approval banner
                                    # and waits for Ctrl+A. Set false to auto-approve
                                    # (CI-style headless flows).

# ─── policy ───────────────────────────────────────────────────────────────
# Per-project orchestration rules. ALL keys optional; defaults shown.
# IMPORTANT: `policy:` is a top-level sibling of `workflow:` — NOT nested inside it.
policy:
  workspace_mode: shared            # default `shared`. Possible values:
                                    #   shared                 — every member runs in --project
                                    #   worktree-per-engineer  — non-lead members get their own
                                    #                            git worktree under
                                    #                            .gala_team/worktrees/<name>
                                    #                            on branch gala_team/<name>

  merge_rule: squash                # default `squash`. Possible values:
                                    #   squash | rebase | merge
                                    # Translates to `gh pr merge --<rule> --delete-branch`.

  pre_merge:                        # default `[]`. List of hooks that must succeed before
                                    # `gh pr create` runs. Each hook spawns a subprocess in
                                    # the project repo's cwd. First non-zero exit blocks the PR.
    - name: lint                    # required. Used in the conversation log.
      cmd: go                       # required. Executable to run.
      args: [vet, ./...]            # optional. Default `[]` (no args).
    - name: test
      cmd: go
      args: [test, ./...]

  post_merge:                       # default `[]`. Same shape as pre_merge. Run AFTER a
                                    # successful `gh pr merge`. Failure surfaces in the
                                    # footer as a warning but doesn't roll back the merge.
    - name: notify
      cmd: scripts/notify-slack.sh
      args: []
```

### Picking the main team

If `teams:` has more than one entry, pick which one drives:

```bash
gala_team --team team.yaml --team-key transpiler
```

The default is the first team in source order. If `--team-key` doesn't match any
team in the file, the binary exits with the list of valid keys.

---

## Cross-team `@consult`

There are two ways to make another team available to the lead:

### 1. In-project (same yaml)

Define multiple teams in `team.yaml`. The lead can `@consult(<key>) … @end`
to hand off to a sibling — same repo, no extra setup.

### 2. Cross-repo registry

Drop a `.gala_team/consults.yaml` next to your project:

```yaml
consults:
  - name: transpiler
    repo: /work/gala_simple
    team: /work/gala_simple/team.yaml
  - name: qa-lib
    repo: ../qa-lib
    team: ../qa-lib/team.yaml
```

`@consult(transpiler)` now spawns a child `gala_team` against the target
repo's `team.yaml`. The child team's stdout streams back live; you can watch
it with **`Tab`** (consult viewer modal).

When the in-project schema and the cross-repo registry both define `<name>`,
the in-project entry wins.

---

## Keyboard

| Key | Effect |
|-----|--------|
| `Enter` | Send composer prompt to the lead. In history mode: open the cursored archive. |
| `Backspace` | Delete last rune from composer. |
| `Tab` | Toggle the consult viewer modal (live tail of every active consult). |
| `Ctrl+A` | Approve the lead's `@summary` → run pre-merge hooks → `gh pr create`. |
| `Ctrl+R` | Reject the summary → back to live conversation. |
| `Ctrl+M` | After `PR created` lands: `gh pr merge` with the configured rule. |
| `Ctrl+H` | Toggle history browser. |
| `↑` / `↓` | History cursor (only when history mode is open). |
| `Esc` | History detail view → back to index. |
| `Ctrl+C` / `Ctrl+Q` | Quit. Closes every live `claude` subprocess first. |

---

## Onboarding & first-prompt payload

The very first message sent to a freshly-spawned `claude` subprocess is
assembled from four sources:

```
# Your role

You are <Member.Name>, the <role> on team <Team.Name>.

## Personality
<Member.personality>

## Additional instructions
<Member.extra_instructions>

# Project onboarding              ← omitted if no onboarding paths

--- docs/CONTRIBUTING.md ---
<file contents>

--- docs/lead-handbook.md ---
<file contents>

# Your task

<the prompt the user typed, or the @consult body, or the @dispatch body>
```

Sources, in order they're stitched:

| Field | Where in yaml | Always sent? |
|---|---|---|
| Member name + role | inferred from `members[].name` / `members[].role` | yes |
| Team name | `teams[].name` | yes |
| Personality | `members[].personality` | when non-empty |
| Extra instructions | `members[].extra_instructions` | when non-empty |
| Team-wide onboarding docs | `teams[].onboarding` (file paths) | when non-empty |
| Per-member onboarding docs | `members[].onboarding` (file paths) | when non-empty |
| The prompt | composer text / `@consult` body / `@dispatch` body | yes |

Subsequent prompts in the same session **do not re-send any of this** —
the model already has the role + onboarding in its context window. Only
the bare prompt goes through.

```yaml
teams:
  - key: main
    name: Skunkworks
    onboarding:                     # team-wide — every member reads these
      - docs/CONTRIBUTING.md
      - docs/ARCHITECTURE.md
    members:
      - role: team_lead
        name: Iris
        personality: |
          Calm, decisive. Asks clarifying questions before delegating.
        extra_instructions: |
          Always cite line numbers when referencing code.
        onboarding:                 # additionally for the lead
          - docs/lead-handbook.md
```

---

## Session history (Ctrl+H)

Every successful `gh pr merge` archives the conversation log to
`.gala_team/sessions/archive/merged-<savedAt>.json`. Press `Ctrl+H` to
browse:

```
  History  ·  ↑↓ navigate · Enter open · Ctrl+H close

  ▶ 2026-04-28 14:32  ·  merged  ·  myproject  (47 lines)
    2026-04-26 09:11  ·  merged  ·  myproject  (62 lines)
    2026-04-25 16:48  ·  merged  ·  myproject  (38 lines)
```

`Enter` loads the selected archive in read-only view; `Esc` returns to the
index.

---

## Workspace modes

`policy.workspace_mode` decides where each member's `claude` runs:

- `shared` *(default)* — every member runs in the project repo. Simpler,
  fastest, fine for chat-based dispatch.
- `worktree-per-engineer` — non-lead members each get a private git
  worktree at `<repo>/.gala_team/worktrees/<member>` on a branch named
  `gala_team/<member>`. Engineers can commit independently without
  fighting over the working tree. The lead always uses the main repo.

---

## Headless mode

For non-interactive use:

```bash
bazel run //cmd/gala_team_headless -- \
    --project /work/myproject \
    --team /work/myproject/team.yaml \
    --prompt "ship the metrics endpoint"
```

Returns a JSON object with the captured conversation, summary, and any
non-fatal errors. Used internally by the `@consult` registry path.

---

## Layout on disk

```
<project>/
├── team.yaml                              # team definition (this file)
└── .gala_team/
    ├── consults.yaml                      # cross-repo consult registry (optional)
    ├── sessions/
    │   ├── latest.json                    # current session — restored on launch
    │   └── archive/
    │       └── merged-<savedAt>.json      # one per successful merge
    └── worktrees/                         # only when workspace_mode = worktree-per-engineer
        ├── Felix/
        └── Theo/
```

---

## Contributing

The codebase is laid out under `app/` by responsibility:

| Path | Owns |
|------|------|
| `app/team` | domain types (`Team`, `Member`, `Role`, `Status`) |
| `app/config` | `team.yaml` parser |
| `app/policy` | `policy:` block + hook runner |
| `app/project` | repo resolution + git checks |
| `app/runtime` | `claude` subprocess lifecycle (spawn / read / send / close) |
| `app/headless` | one-shot non-interactive driver |
| `app/onboarding` | onboarding-doc loader + prompt wrapper |
| `app/consult` | cross-team consult registry, runner, streaming pump |
| `app/session` | conversation log persistence + history archiving |
| `app/directive` | `@dispatch` / `@consult` / `@summary` parser |
| `app/fsm` | pure orchestration state machine |
| `app/ui` | Elm `model` / `update` / `view` |
| `app/view` | reusable widgets (team panel, pipeline view) |
| `cmd/` | binaries: `gala_team` (TUI), `gala_team_headless` |

Run the test suite:

```bash
bazel test //app/...
```

Internal design notes live under `docs/private/`.
