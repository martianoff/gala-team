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

1. **Define your team** in `team.yaml` at the project root:

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
   policy:
     workspace_mode: shared          # or worktree-per-engineer
     merge_rule: squash              # or rebase / merge
     pre_merge:
       - name: lint
         cmd: go
         args: [vet, ./...]
       - name: test
         cmd: go
         args: [test, ./...]
   ```

2. **Run** in your project directory:

   ```bash
   gala_team --project . --team team.yaml
   ```

3. **Type a prompt**, press `Enter`. Watch the team work.

4. When the lead emits `@summary`, the banner switches to **approval mode**.
   Press `Ctrl+A` to fire `gh pr create`, then `Ctrl+M` to merge.

---

## team.yaml schema

The schema supports **multiple teams in one file**:

```yaml
teams:
  - key: main                       # how @consult / --team-key reference it
    name: Skunkworks                # display name (TUI header)
    description: Product team       # one-liner (TUI header subtitle)
    onboarding:                     # optional: paths read into TL context
      - docs/CONTRIBUTING.md        # before the first prompt
      - docs/ARCHITECTURE.md
    members:
      - role: team_lead
        name: Iris
        personality: …              # free-form text fed to the system prompt
        model: claude-opus-4-7      # optional; pins the model
        extra_instructions: |
          Strict pattern-matching in pull-request prose.
        onboarding:
          - docs/lead-checklist.md  # per-member onboarding, in addition to team-wide
  - key: transpiler
    name: Transpiler Wizards
    description: Compiler / language work
    members:
      - role: team_lead
        name: Theo
        personality: Precise. Cites specs.
      - role: engineer
        name: Cade
        personality: Pragmatic.

workflow:
  qa_required: true                  # default true; if false, `qa` members optional
  parallel_engineers: true           # default true
  approval:
    require_user_confirm: true       # default true

policy:
  workspace_mode: shared              # `shared` | `worktree-per-engineer`
  merge_rule: squash                  # `squash` | `rebase` | `merge`
  pre_merge:                          # blocks `gh pr create` until they pass
    - {name: lint, cmd: go, args: [vet, ./...]}
    - {name: test, cmd: go, args: [test, ./...]}
  post_merge:                         # runs after `gh pr merge` succeeds
    - {name: notify, cmd: scripts/notify-slack.sh}
```

**Backwards compatible** — the legacy single-team shape still works:

```yaml
team:
  name: Skunkworks
  members: [...]
workflow: {...}
```

This produces a one-entry `teams` list with `key: main`.

### Picking the main team

If `teams:` has more than one entry, pick which one drives:

```bash
gala_team --team team.yaml --team-key transpiler
```

The default is the first team in source order.

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

## Onboarding docs

Each team and each member can declare a list of file paths under
`onboarding:`. Their contents are prepended to the **first** prompt the
member receives, so the model has the context before its first response.

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
        onboarding:                 # additionally for the lead
          - docs/lead-handbook.md
```

Subsequent prompts in the same session don't re-send the docs — the model
keeps them in its context window.

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
