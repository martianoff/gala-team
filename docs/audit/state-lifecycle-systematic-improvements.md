# State & lifecycle: systematic improvements

Cross-cutting audit of ~21 `fix(...)` commits in the orchestrator / FSM /
runtime / build layer. The goal is not 21 postmortems — it is the small set
of **root-cause classes** each of which broke independently at several sites,
and the **single structural mechanism** that converts each class from
"hold it by hand at every site" into "impossible to get wrong."

Evidence is cited as `file:line` against current `master`-forked source, not
commit prose. Commit short-SHAs are the evidence ledger only; bug shapes are
described generically.

---

## Meta-thesis

Almost every commit in the lifecycle/worktree families has the same shape:
**a chokepoint already exists, and the bug is a new code path that didn't
route through it.**

The codebase already has good chokepoints —
`transitionLogged` (`app/ui/update.gala:181`) for FSM transitions,
`closeLiveSession` (`app/ui/update.gala:1948`) for killing a live subprocess,
`resetMemberState` (`app/ui/update.gala:3181`) for clearing per-subprocess
scratch, `LeadWorktreePath`/`LeadBranchFor`
(`app/runtime/runtime_glue.gala:184`, `:154`) for the lead git target.
Every one of these chokepoints was *added in response to a bug* — and then a
later bug recurred because a **different** entry path open-coded the thing
the chokepoint was supposed to own:

- `f2fdcdf` — a plain-chat TL turn assigned `State = Idle()` directly,
  bypassing `transitionLogged`, so the transition never reached the audit
  log. Fixed by routing the empty-directive case through
  `transitionLogged(... TLDone(empty) ...)` (`app/ui/update.gala:181`).
- `4d733f9` / `997fdfc` / `2ef55c1` / `07927ff` — four *different* respawn
  paths each had to independently learn "kill the live subprocess first."
- `69e0560` — the resume/recovery path reached the `Approval` state without
  the body gate the live path had.
- `86c1baa` / `db61812` — hook-runner and readiness-probe each re-derived
  their git target by hand and each picked the wrong one.

So the recommendations below are not "add a guard at site X." They are
"make the chokepoint the *only* way to reach the behavior, and add a
~one-line test that fails if any other caller appears."

---

## Root-cause classes

| # | Class | Commits (short-SHA) | Shared defect | Blast radius |
|---|---|---|---|---|
| C1 | Spawn/respawn lifecycle not structural | `4d733f9` `997fdfc` `2ef55c1` `07927ff` `8eecd10` (`4c80e68` `73ca48d` partial) | Each (re)spawn path must independently (a) kill the prior live process, (b) reset the heartbeat clock, (c) clear per-subprocess scratch/watermarks. Held by convention per-site, not by one entry. | Double subprocesses under one name; fresh process auto-marked stuck/abandoned within ~50 ms; permanent member abandonment; stuck QA never recovered. |
| C2 | Idempotency / dedupe is ad-hoc per-event | `4d733f9` `73ca48d` `997fdfc` `f2fdcdf` | "Process this once per turn" is re-implemented per event with a bespoke mechanism (`MemberDoneBodies` watermark, `dedupTargetsByName`, `ConsultsFired`/`MemberDirectivesFired` index, `PendingClosures` counter). New events get no dedupe by default. | Doubled FSM transitions on post-`@done` EOF; one logical dispatch fanned to N spawns; stale buffer re-fired prior-turn directives → self-perpetuating dispatch livelock. |
| C3 | Quality/readiness gate not on every entry path | `69e0560` `db61812` `1f38250` `41f77be` | `Approval` state has several producers (live `@summary`, auto-approve, resume/recovery); the body/readiness gate was enforced per-producer, so a new producer bypassed it. | Internal worktree/escalation prose shipped verbatim to a **public** PR; every `@summary` rejected (deadlock) when the probe asked the wrong ref. |
| C4 | Lead-worktree / lead-ref not structural | `86c1baa` `db61812` `41f77be` `1f38250` | Every git/build op re-derives its target (cwd + ref) by hand; nothing forces cwd = lead worktree, ref = lead branch. | Pre-merge hooks validated the user's stale checkout (and walked into nested build symlinks); readiness probed an always-zero range → permanent rejection; batch/stacked PRs force-pushed over each other. |
| C5 | "The subprocess is still alive" assumption | `bf1799a` `4c80e68` `93c2350` `10a21d4` `73ca48d` `2f3b94a` | `claude --print` exits at every turn-end; code wrote to / waited on / `--resume`d a handle whose process was already gone, or failed to persist the state needed to resume it. | ~1 h hard deadlock (stdin never EOF'd, buffered `@dispatch` never parsed); answers written to a dead pipe and silently lost; `--resume` against an unregistered id → member blocked forever; post-recovery TL amnesia. |
| C6 | Build/test-graph hygiene not gated | `1cf3c19` `bdfbfec` `4a36ac9` `c9fc7aa` | Bazel `srcs`/`deps`, the internal-test target shape, test-file `package`, and a hand-written decoder are all manual mirrors of the source tree with no CI sync gate. | Targets "silently broken on master"; consumer builds fail `undefined: <Symbol>`; testdriver fails to compile on struct growth. |

Overlaps are real and informative: `db61812` is both C3 (gate gave a wrong
answer) and C4 (it probed `HEAD` instead of the lead ref); `73ca48d` is C2
(duplicate-chunk dedupe) and C5 (stale `--resume`); `4d733f9` straddles C1
and C2. The classes interact through the **spawn boundary** and the
**Approval boundary** — which is exactly where the structural fixes sit.

---

## Structural fixes

### C1 — One spawn chokepoint every (re)spawn path must route through

**The invariants, and the sites each must hold at today:**

| Invariant | Must hold at | Evidence it broke / now holds |
|---|---|---|
| Kill the prior live subprocess before (re)spawn | TL submit; TL nudge; engineer dispatch; QA review; QA in-place re-prompt; crash respawn; heartbeat-silence respawn; pending-answer re-delivery; consult spawn | `closeLiveSession` `app/ui/update.gala:1948`; bumps `PendingClosures` at `:1960` so the dead process's trailing EOF is dropped, not mistaken for the fresh one |
| Reset the heartbeat clock (`LastChunkAt`) to *now* on every spawn / transition-into-working | `ensureSession` success; `setStatus` idle→working; every respawn | `ensureSession` `app/ui/update.gala:2010`; `setStatus` `:4724` (only on `!wasWorking && nowWorking`, `:4720`); `resetMemberState` `:3188` |
| Clear per-subprocess scratch (`MemberBuffers`, `MemberJsonBuf`, `MemberDirectivesFired`, `MemberDoneBodies`, `MemberBlockedReasons`) before a re-spawn parses | every fresh dispatch & every respawn | `resetMemberState` `app/ui/update.gala:3182-3189`; TL-side equivalent (`TurnBuffer`/`ConsultsFired`) in `spawnTLNudge` `:420-423` |

The codebase already converged the *mechanism* into two helpers
(`closeLiveSession` + `resetMemberState`/`resetMemberForFreshDispatch`/
`resetMemberForRespawn`, `app/ui/update.gala:3204`/`:3213`). What is **not**
structural is the *ordering contract*: every spawn site still hand-assembles
`closeLiveSession(...) → resetMember*(...) → ensureSession(...)`. `spawnTLNudge`
even open-codes the TL-side reset (`:420-423`) instead of going through
`resetMemberState`.

**Chokepoint:** introduce one `spawnFor(m, member, kind)` (kind ∈
`{freshDispatch, tlSubmit, tlNudge, qaReview, qaReprompt, crashRespawn,
silenceRespawn, answerRedelivery}`) that internally does
`closeLiveSession → resetMemberState(freshTask = kind.isFresh) → ensureSession`
and is the **only** caller of `ensureSession`/`SpawnSession`. Make
`ensureSession` and `runtime.SpawnSession` package-private behind it. The
TL-side per-turn fields (`TurnBuffer`, `ConsultsFired`) become part of
`resetMemberState` when the member is the lead, killing the `spawnTLNudge`
open-code.

**Test that makes it cheap to keep:** a grep/lint test (a `_test.gala` that
shells `git grep`) asserting `SpawnSession(` / `ensureSession(` appears only
inside `spawnFor`; plus an FSM property test: for every spawn `kind`, after
the reduction `LastChunkAt[name] == NowAt`, `MemberBuffers[name]` empty,
`Sessions` has exactly one handle for `name`.

**Effort: M.** Mechanism exists; this is consolidation + making two functions
private + one lint test.

### C2 — A single per-turn watermark abstraction

Today there are four hand-rolled "process once" mechanisms:

- `MemberDoneBodies.Get(name) != ""` as the in-turn watermark that stops the
  post-`@done` EOF re-firing `MemberDone` — `app/ui/update.gala:3055-3058`.
- `dedupTargetsByName` collapses duplicate `(name, body)` dispatch tuples
  from a doubled claude chunk — `app/ui/update.gala:3382-3391`, applied in
  `spawnDispatchedMembers`.
- `ConsultsFired` / `MemberDirectivesFired` as a high-water *index* into the
  parsed-directive list so only directives past the mark fire.
- `PendingClosures` as a stale-event filter so a killed process's EOF is
  dropped — `app/ui/update.gala:1957-1960`.

All four are the same shape: *an event/directive identified by (scope, turn,
index) must take effect exactly once*. They differ only in scope key and in
whether the mark is a bool, a count, or an index.

**Abstraction:** a `TurnGate` keyed by `(scope, turnId)` where `scope ∈
{member-name, "TL", consult-name}` and `turnId` is a monotonic per-scope
counter:

```
processedThrough(scope) : Int          // high-water index, default 0
markProcessed(scope, n)                 // raise the water line
bumpTurn(scope)                          // new turn → water line resets
```

- Directive dispatch: fire `parsed[i]` iff `i >= processedThrough(scope)`;
  then `markProcessed(scope, parsed.Size())`. Subsumes
  `ConsultsFired`/`MemberDirectivesFired` *and* makes `dedupTargetsByName`
  unnecessary (a re-flushed chunk yields the same indices, already below the
  water line).
- `MemberDone`: a degenerate one-slot gate — fire iff not yet marked.
- `PendingClosures`: `bumpTurn` on kill; the dead process's EOF carries the
  old `turnId` and is dropped.

The decisive win is **C1↔C2 coupling**: the spawn chokepoint from C1 calls
`bumpTurn(scope)` once. That single call structurally invalidates *every*
per-turn watermark, replacing the scattered `.Copy(TurnBuffer = "",
ConsultsFired = 0, MemberBuffers = …Remove(name), …)` rituals (`:420-423`,
`:3182-3189`) that each spawn site re-derives today and that `997fdfc`/
`4d733f9` show are easy to forget at a new site.

**Test:** property test — replay a stream that emits every directive twice
and emits the post-`@done` EOF; assert each directive's effect (spawn,
transition) occurs exactly once for any interleaving.

**Effort: M–L.** The most invasive change; do it *with* C1 (same boundary).
Lower standalone priority because the ad-hoc mechanisms currently work — the
value is that new events get dedupe by construction.

### C3 — A single guarded constructor for the `Approval` state

The recurring defect (`69e0560`) is not the validator's location — there is
exactly one validator, `validatePrBody` (`app/ui/update.gala:3465`, with the
internal-path-leak list at `:3508-3520`) and one readiness check,
`checkPrReady` (`:5068`). The defect is that **the transition into
`Approval` has multiple independent producers** and only some ran the gate
before transitioning:

- live `@summary` / auto-approve → `onSummaryReadyResult` runs
  `checkPrReady` + `validatePrBody` before the synthetic approve.
- manual approve → `onApprovalReadyResult` runs `checkPrReady`.
- resume/recovery → `recoverApprovalIfReady` (`app/ui/update.gala:4954`).
  This path is the one `69e0560` had to retrofit: it now calls
  `checkPrReady` (`:4972`) **and** `validatePrBody` (`:4974`), and on a bad
  body spawns the same nudge the live path uses (`:4982-4984`) instead of
  silently dropping to `Idle`. But it had to *learn* the gate the live path
  already had.

**Chokepoint:** `enterApproval(m, body) Tuple[AppModel, Cmd[AppMsg]]` —
the **only** function permitted to yield `State = Approval(...)`. It runs
`checkPrReady` then `validatePrBody`, routes failure to
`buildBadSummaryBodyNudge` via `spawnTLNudge`, and only on success returns
`m.Copy(State = Approval(SummaryBody = body))` (today that raw constructor is
written at `:4986` *and* in the inline `@summary` handler — those become
calls to `enterApproval`). `recoverApprovalIfReady` collapses to: find body →
`enterApproval`.

**Test:** lint test asserting the literal `Approval(SummaryBody` appears only
inside `enterApproval` and the FSM module; plus an FSM property test: in any
reduction that ends in `State = Approval`, the same reduction contained a
`validatePrBody` call returning `None` and a `checkPrReady` returning `None`.

**Effort: S–M.** Recovery path already does the right thing; this is
hoisting the common sequence into one function and forbidding the raw
constructor by lint.

### C4 — One lead-targeted git primitive

Every orchestrator git/`gh` op currently re-derives its target by hand, and
each historical bug is a site that derived it wrong:

| Op | Where | Target today |
|---|---|---|
| pre-merge hooks | `runOne` `app/policy/runner.gala:103` (cwd param at `:108`) | caller-supplied `cwd` — `86c1baa` made the caller pass the lead worktree (`hooksFutureCmd`, `app/ui/update.gala:5148`) |
| readiness probe | `checkPrReady` `app/ui/update.gala:5068` | `proj.Repo` cwd but ref `proj.DefaultBranch..<leadRef>` (`:5070`,`:5075`) — `db61812` fixed this from `..HEAD` |
| ref-missing disambig | `refMissing` `:5123` | same shape |
| `gh pr create` + snapshot push | `GhPrCreateFuture` `app/runtime/runtime_glue.gala:882` | `LeadWorktreePath(proj)` `:886` |
| `gh pr merge` | `GhPrMergeFuture` `:1144` | `LeadWorktreePath(proj)` `:1146` |
| post-merge hooks | `onMerged` | `proj.Repo` — the **one** correct exception (lead worktree is wiped post-merge) |

The branch-identity sub-defect (`1f38250`/`41f77be`) is the same disease:
`prBranchOverrideFor` (`app/ui/update.gala:5198-5202`) is now the single
decision point for "reuse branch vs cut fresh," but it had to be retrofitted
into both `gh pr create` call sites after they each open-coded
`m.ActivePrBranch`.

**Chokepoint:** `leadGitOp(proj, argv) Result` in `runtime_glue` — sets cwd =
`LeadWorktreePath(proj)` unconditionally and is the only spawner of `git`/`gh`
for orchestration. `checkPrReady`/`refMissing` take ref-shaped helpers
(`leadRange(proj)` = `DefaultBranch..LeadBranchFor(proj)`), and the policy
runner's pre-merge cwd is forced to the lead workspace inside the runner, not
left to the caller (so a future caller can't repeat `86c1baa`). Post-merge is
the single annotated exception.

**Test:** lint test — any `subprocess.*"git"` / `"gh"` spawn outside
`leadGitOp` (allowlist: post-merge) fails CI. Cheap and total.

**Effort: M.** Resolvers exist (`LeadWorktreePath`/`LeadBranchFor`); this
funnels ~5 call sites through one wrapper and adds the allowlist lint.

### C5 — "Single-turn subprocess" as a stated, tested invariant

The root assumption behind `bf1799a`, `4c80e68`, `93c2350`, `10a21d4`,
`73ca48d`, `2f3b94a`: a `MemberSession` handle is **single-turn** —
`claude --print` exits at turn-end (`app/runtime/runtime_glue.gala:1966-1969`
documents this), so after a `result`/turn-end event the process is gone.
Bugs in this class either (a) wrote to / waited on the dead handle, or
(b) failed to persist the state required to spawn a *fresh* `--resume` turn.

The fixes already encode the right behavior in scattered spots:
- turn-end closes stdin unconditionally (no longer gated on
  `PendingQuestion.IsEmpty()`) so EOF always reaches the failure handler;
- the pending-answer path re-delivers via a fresh `--resume` turn
  (`closeLiveSession` → `ensureSession`) instead of a tool-result to a dead
  pipe;
- `looksLikeStaleSessionError` (`app/ui/update.gala:3367-3373`) detects
  "no conversation found / session not found" and drops the bad
  `SessionId` so the next spawn is fresh;
- `2f3b94a` made the snapshot round-trip `SessionIds`
  (`serialiseSessionIds` `app/ui/update.gala:2833`) so a post-recovery TL
  resumes the prior session instead of starting amnesiac.

**Invariant to state once (in code + docs):** *No code may `Send*`/`Close*`/
`await` an existing `MemberSession` across a turn boundary. Every cross-turn
interaction goes through the C1 spawn chokepoint (fresh `--resume` turn).
Any state needed to resume must survive a process restart, which means it
must round-trip the snapshot symmetrically.*

**Test shape that catches the whole class at design time:** a
`DeadAfterOneTurn` mock runtime in `app/ui` tests — it reports
`process exited` for **any** send/await issued after the first turn-end.
Replay every cross-turn flow against it (answer a pending question, TL
nudge, re-dispatch, QA in-place re-prompt, recovery resume). Any path that
touches the old handle instead of routing through the spawn chokepoint fails
loudly. Add the snapshot symmetry unit test: `deserialiseSessionIds(
serialiseSessionIds(m)) == m.SessionIds` for non-empty maps (`app/ui/update.gala:2833`,
`cmd/main.gala` deserialise).

**Effort: S.** The behavior is mostly already correct post-fixes; the
leverage is the mock + the symmetry test that prevent regression and would
have caught every commit in this class pre-merge.

### C6 — One whole-graph build/test gate in CI

All four are the same disease: hand-maintained mirrors of the source tree
with **no automated sync gate**. CI today runs only `gala build -o gala_team
./cmd` and `gala test` (`.github/workflows/ci.yml:43-44`, `:64-70`) — it
never invokes Bazel. `gazelle` is a declared `bazel_dep`
(`MODULE.bazel:9`) but there is **no `//:gazelle` target** — the root
`BUILD.bazel` is four lines of `exports_files`. So a stale `srcs`/`deps`
(`1cf3c19`), a missing internal-test shape (`bdfbfec`), or a wrong-package
test file (`4a36ac9`) can sit on `master`; `gala test`/`gala build` catch the
last two only incidentally, and the testdriver/struct drift (`c9fc7aa`) is
caught only because constructor arity is a hard type error — a *defaulted*
new field would drift silently.

CLAUDE.md already documents two of these as conventions
(`CLAUDE.md` "Internal-package tests" and the Windows `bazel test`
workaround) — prose guidance, not a gate, which is exactly why the class
recurs.

**Chokepoint:** add a `gazelle` target to the root `BUILD.bazel` and one CI
job: `bazel run //:gazelle -- -mode=diff` (assert no diff) then
`bazel test //...`. The gazelle-diff step catches stale `srcs`/`deps`;
`bazel test //...` fails loudly on the internal-test-shape and wrong-package
regressions; the testdriver build catches arity drift. Belt-and-suspenders
for `c9fc7aa`: a decoder round-trip test (encode every `AppMsg` variant,
assert the testdriver decoder reconstructs it field-for-field) — the only
thing that also catches a *silently-defaulted* new field.

**Effort: S.** One root target + one CI job + one round-trip test.

---

## Prioritized recommendations

Ranked by impact × inverse effort. "Impact" weights both recurrence count
and severity (a public-PR leak or a 1 h deadlock outranks an internal nudge).

1. **C6 — CI `bazel test //...` + `gazelle -mode=diff` gate. Effort S.**
   Highest leverage: kills an entire recurring class (4 commits) outright,
   near-zero risk, no production-code change, ~half a day. The class is
   defined by "no gate exists"; adding the gate ends it.

2. **C1 — single `spawnFor` spawn chokepoint + spawn-site lint. Effort M.**
   Highest *impact*: the densest class (7+ commits, the deepest deadlocks
   and the double-process / instant-abandon failures). The mechanism is
   already 80 % built (`closeLiveSession` + `resetMemberState`); the work is
   making it the *only* path and pinning that with a one-line grep test.
   Also unlocks the cheap form of C2.

3. **C3 — `enterApproval` single guarded constructor. Effort S–M.**
   Highest *severity per occurrence*: the bypass shipped internal worktree
   prose to a **public** PR (the exact failure CLAUDE.md exists to prevent).
   Small surface — recovery already does the gating; this hoists it and
   forbids the raw `Approval(...)` constructor by lint.

4. **C5 — `DeadAfterOneTurn` mock runtime + snapshot-symmetry test.
   Effort S.** Cheap insurance on an already-mostly-fixed but
   highest-deadlock class. The mock would have caught `bf1799a`/`4c80e68`/
   `93c2350` pre-merge. Pure test code; no risk.

5. **C4 — `leadGitOp` single lead-targeted git primitive + spawn lint.
   Effort M.** Medium frequency, high blast (mutating/validating the wrong
   repo). Resolvers exist; this is funnelling ~5 sites + an allowlist lint.

6. **C2 — `TurnGate` per-turn watermark abstraction. Effort M–L.**
   Do it *with* C1 (same spawn boundary; `bumpTurn` is one call in
   `spawnFor`). Lowest standalone priority — the ad-hoc mechanisms currently
   work; the payoff is that new events get dedupe by construction rather
   than after the next livelock.

**Cross-cutting (do alongside #2–#5): the chokepoint lint pattern.**
The meta-thesis says every recurrence is "a new path that skipped an
existing chokepoint." The single highest-leverage *preventive* mechanism is
to make each chokepoint's underlying primitive un-callable from elsewhere:
one tiny `_test.gala` per chokepoint that `git grep`s the raw primitive
(`SpawnSession`/`ensureSession`, raw `Approval(`, `git`/`gh` spawn,
direct `State =` assignment vs `transitionLogged`) and fails if it appears
outside the chokepoint's allowlist. Each is ~S effort and converts the
"route through X" convention — the thing that broke in `f2fdcdf`,
`69e0560`, `86c1baa`, and every C1 commit — into a hard CI failure for the
*entire* meta-class, including paths not yet written.
