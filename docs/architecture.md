# gala_team architecture

A compact map of the orchestrator's components and how they fit together. Read this before editing across package boundaries.

## Layered overview

```
                ┌─────────────────────────────────────────────────┐
                │ ui / view / cli   ←  user-visible TUI + state   │
                │ fsm               ←  orchestration state machine │
                │ protocol / directive  ←  TL/member message contract │
                │ agent / runtime   ←  agent-port + claude transport │
                │ team / project / policy / config / onboarding   │
                │                       ←  domain + config        │
                └─────────────────────────────────────────────────┘
```

Higher rows depend on lower rows; lower rows know nothing of higher ones. A future non-claude agent (remote, different vendor) plugs in at the `agent` port without anything above it noticing.

## Packages

### Domain + configuration

- **`app/team`** — leaf domain types: who's on the team, their role (TL / engineer / QA). Pure value objects, no IO.
- **`app/project`** — the workpiece: the git repo the team operates on. Distinct from `team` (a team is reusable across projects).
- **`app/policy`** — declarative orchestration rules (heartbeat thresholds, guardrails, hooks, merge style). The Heartbeat ceiling (`30/120/300/2`) and the 800-line diff cap live here.
- **`app/config`** — `team.yaml` loader: codec-decode + post-decode validation into `Team` + `Workflow` + `Policy`.
- **`app/onboarding`** — per-team / per-member onboarding pack: markdown docs threaded into the agent's first prompt.
- **`app/guidance`** — project standing orders (TESTING.md, CLAUDE.md, repo conventions) the TL is expected to honour.

### Agent abstraction + transport

- **`app/agent`** — the **transport-neutral agent port**. `AgentSession`, `AgentTransport`, `AgentEvent` (`AgentChunk` / `AgentDiagnostic` / `AgentTurnEnded` / `AgentFailed`). Everything above this port speaks in terms of those four events.
- **`app/runtime`** — the local-`claude`-CLI implementation of that port. Owns: argv flags, stream-json wire envelopes, stdout/stderr → `AgentEvent` classifiers, auth-error detection, the predicate naming claude-code's long-running tools (`Task`, `Workflow`). **All claude-code-specific knowledge lives here.**

### Communication protocol

- **`app/protocol`** — the **directive contract** the agent and orchestrator speak. The inbound decoder (`Decode` / `DecodeWithIssues`) is a pure function of the accumulated agent text buffer; surfaces grammar-level diagnostics (`UnclosedBlock`, `MultiTargetDispatch`, `EmptyBody`) so the UI can nudge the TL when a directive shape is wrong.
- **`app/directive`** — the FSM-side representation of decoded messages. The protocol layer hands a `Message`; `FromMessage` adapts it to `Directive` for FSM consumption. Eight kinds: Dispatch / Consult / Summary / Base / Plan / Finished / Help / Blocked.

### Orchestration

- **`app/fsm`** — the **pure orchestration state machine**. States: `Idle`, `TLThinking`, `Delegating`, `QAGate`, `TLReview`, `TLNudging`, `Approval`. Inputs are directives + lifecycle events; outputs are state transitions. No IO; tested as a pure function.
- **`app/consult`** — cross-team consultation: when the TL invokes `@consult(<team-id>)`, the consult registry resolves the target team and proxies the conversation.

### UI / state model

- **`app/ui`** — the AppModel + `Update` function. Holds: live sessions, conversation, FSM state, `OutstandingTaskTools`, `LastChunkAt`, `SyntheticOnlyChunks`, `TurnBuffer`, watchdog math. The stream-json envelope filter (`filterClaudeStreamJsonFor`) and the TL-nudge / member-nudge pipelines live here.
- **`app/view`** — read-only renderers: conversation transcript, pipeline mini-graph, status bar, toast deck.
- **`app/cli`** — input-event → `AppMsg` translation (keymap, command parser). Lives separately so `cmd/main` stays thin.

### Supporting

- **`app/session`** — durable session store (rolling `latest.json` snapshot + `archive/` history + `debug/events.jsonl` + per-member stream traces).
- **`app/headless`** — alternative runner that drives the same `Update` without a TTY (CI / automated tests / scripted workflows).
- **`app/testdriver`** — JSON-over-stdio test harness; replaces gala-tui's TTY runtime when launched with the test flag.
- **`app/util`** — generic collection helpers shared across packages.
- **`app/version`** / **`app/buildinfo`** — release version + build SHA surfaced in the TUI brand line.

## How a turn flows

1. **User prompts** → `cli` translates the input event → `ui.Update` receives `UserPrompted` → `fsm` transitions to `TLThinking` → `runtime` opens / resumes a `claude` session for the TL via the `agent` port.
2. **Agent streams chunks** → `runtime.classifyClaudeRead` maps each stdout line to `AgentChunk` → `ui.onChunk` collects into `TurnBuffer`, parses through `filterClaudeStreamJsonFor`, tracks tool_use lifecycle in `OutstandingTaskTools`, bumps `LastChunkAt`.
3. **Turn ends** → `runtime` emits `AgentTurnEnded` → `ui.onSessionFailed` runs `protocol.DecodeWithIssues` against the final `TurnBuffer` → directives flow into `fsm` via `directive.FromMessage` → next state.

## Cross-cutting invariants

- **No claude-code knowledge above `app/runtime`.** Tool names, stream-json envelope shapes, CLI flags are runtime-only. The orchestration FSM and protocol must work against any `AgentTransport`.
- **Protocol is grammar.** `DecodeIssue` surfaces structural problems with directive syntax. Semantic / heuristic complaints about TL prose do not belong in `app/protocol`.
- **Orchestration is in the orchestrator, not config.** `team.yaml` stays declarative; behaviour belongs in `app/ui` / `app/fsm`.
- **The session store is the audit trail.** `events.jsonl` and per-member traces are the source of truth for "what happened in this run" — read them before guessing.
