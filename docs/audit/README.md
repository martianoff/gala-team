# Systematic improvements audit

Two parallel audits of ~30 historical `fix(...)` commits, split by failure
surface:

- [`state-lifecycle-systematic-improvements.md`](state-lifecycle-systematic-improvements.md)
  — orchestrator / FSM / runtime / build (~21 commits).
- [`operator-ux-systematic-improvements.md`](operator-ux-systematic-improvements.md)
  — anything the operator sees, can't see, can't click, or can't type into
  (~9 commits).

This file is the synthesis: the single finding both halves converge on, the
one currently-shipping defect the audit uncovered, and **one** prioritized
list across both.

---

## The single root finding

Almost every fix in the corpus has the same shape, stated two ways by the two
audits:

- **State half:** *a chokepoint already exists, and the bug is a new code
  path that didn't route through it.* Each chokepoint
  (`transitionLogged`, `closeLiveSession`, `LeadWorktreePath`,
  `validatePrBody`) was added in response to a bug, then a later bug recurred
  because a *different* entry path open-coded the thing the chokepoint owned.
- **Operator half:** *model state changed without its contractually-coupled
  surface moving with it* — input routing, off-thread execution, the
  discovery surfaces (footer/help/palette/keymap), or the liveness signal.

These are the same disease. The corpus is not 30 unrelated bugs; it is a
handful of **missing structural constraints**, each of which was patched at
one site while leaving every other (current and future) site free to repeat
it. The remedy is uniform: convert each "everyone must remember to route
through X" convention into a constraint that **fails the build/test when a
new path doesn't** — a guarded constructor, a single primitive, a registry,
or a grep/property gate.

## Live defect found during the audit (not yet shipped as a fix)

`recoverApprovalIfReady` (`app/ui/update.gala:4954`) calls `checkPrReady`
**synchronously on the UI thread** (`app/ui/update.gala:4972`), reachable
from the post-recovery resume handler (`app/ui/update.gala:778`). This is the
identical blocking-`git`-on-the-event-loop shape that the off-thread sweep
fixed at four sibling sites — this third caller of `checkPrReady` was never
converted. It is a currently-shipping freeze risk and is itself the strongest
argument for a *mechanical* gate over author vigilance. Tracked as item 1
below.

## Unified priority list

Ranked by impact × inverse effort across both audits. Where the two reports
proposed mechanisms that close the same gap, they are merged into one item.

| # | Improvement | Closes | Effort | Why this rank |
|---|---|---|---|---|
| 1 | **Blocking-IO grep gate** wired into `bazel test`: no message handler may call a blocking primitive directly; all subprocess/git/clipboard IO leaves via a `FutureCmd`. | UI-thread freeze class; **immediately flags the live `recoverApprovalIfReady` defect** and the deferred `ensureSession` chain as known violations. | S | Pure-text check, zero refactor, catches a whole crash-looking class at review time every time. The cheapest mechanism with the highest blast-radius reduction. |
| 2 | **CI `bazel test //...` + `gazelle -mode=diff` gate** (add a `//:gazelle` target; CI never invokes Bazel today). | Build/test-graph hygiene class outright (stale `srcs`/`deps`, internal-test shape, wrong-package test, decoder/struct drift). | S | The class is *defined by* "no gate exists." Adding the gate ends it; no production code touched. |
| 3 | **Single `spawnFor` chokepoint** every (re)spawn routes through (`closeLiveSession → resetMemberState → ensureSession`), with a spawn-site lint. Subsumes the deferred off-thread `ensureSession` work and unlocks item 6. | Spawn/respawn lifecycle class (densest: double processes, instant-abandon, permanent abandonment, deadlocks). | M | ~80% of the mechanism already exists; the work is making it the *only* path and pinning that with a one-line grep test. Highest aggregate impact. |
| 4 | **Modal contract registry** (`ModalSpec`: whitelist-by-construction intercept + derived mouse capture) + fold-over-`allModals` tests. | Modal input class — three field reports ("modal dead", "buttons don't click", "no Tab") were one missing contract. | M | Highest *recurrence* on the operator side; makes a leaky modal #N impossible to ship. |
| 5 | **`enterApproval` single guarded constructor** — the only producer of `State = Approval`, runs `checkPrReady` + `validatePrBody` on every path (live / auto / resume), forbids the raw constructor by lint. | Gate-not-on-every-path class. Highest *severity per occurrence*: a bypass shipped internal prose to a **public** PR. | S–M | Recovery path already does the gating; this hoists it and bans the bypass. |
| 6 | **Capability table + every-surface test** tying each model field / `AppMsg` to footer · keymap · help · palette · testdriver. | "Feature added state but a discovery surface stayed stale" class. | M | Converts a review checklist that already failed twice into a mechanical failure naming the missing surface. |
| 7 | **`leadGitOp` single lead-targeted git primitive** (cwd = lead worktree, ref = lead branch) + spawn lint with a post-merge allowlist. | Wrong-repo / wrong-ref class (hooks validated stale tree; readiness probed always-zero range; batch PRs clobbered each other). | M | Resolvers exist; this funnels ~5 sites through one wrapper. |
| 8 | **`DeadAfterOneTurn` mock runtime** + snapshot-symmetry test. | "Subprocess still alive across a turn" assumption (the deepest deadlocks). | S | Pure test code; would have caught the worst deadlocks pre-merge. Cheap regression insurance on an already-mostly-fixed class. |
| 9 | **Loop-liveness header indicator** (tick-cadence driven, independent of member status) + durable-before-toast failure assertions. | "Looks frozen" perceptual class — the only signal that separates a stalled loop from an idle-but-alive app. | S–M | Closes the perceptual gap that makes freeze and silent-failure bugs indistinguishable to the operator. |
| 10 | **`TurnGate` per-turn watermark abstraction** subsuming the four ad-hoc "process once" mechanisms. | Idempotency/dedupe class (doubled transitions, fanned dispatch, stale-buffer livelock). | M–L | Do *with* item 3 (same spawn boundary; `bumpTurn` is one call in `spawnFor`). Lowest standalone priority — the ad-hoc mechanisms currently work; the payoff is dedupe-by-construction for new events. |

**The meta-pattern, made cheap:** items 1, 3, 5, 7 all share one preventive
primitive — a tiny `_test.gala` per chokepoint that greps the raw underlying
primitive and fails if it appears outside that chokepoint's allowlist. Each
is ~S effort and converts the "route through X" convention — the exact thing
that broke across the whole corpus — into a hard CI failure for paths not yet
written.

**Sequencing.** Ship items 1 and 2 first (both S, no production-code change,
self-proving — item 1 flags the live defect the moment it lands). Then the
two M-effort consolidations that retire the densest classes (3, 4). Items 5,
7 fold in the chokepoint-lint pattern. 8, 9 are cheap regression/perception
insurance. 10 rides on 3.
