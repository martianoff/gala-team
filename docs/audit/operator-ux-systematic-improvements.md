# Operator-UX systematic improvements

Scope: ~9 historical `fix(...)` commits that all surface as something the
human operator **sees, can't see, can't click, or can't type into**. The
goal here is not nine postmortems — it is the small number of *structural
rules* that, if enforced, retire each whole class so a new modal / feature /
IO call cannot reopen it.

Every commit in the set collapses into one of four root-cause classes. Each
class is a missing *contract* between a piece of model state and the
surfaces that must move in lockstep with it.

---

## Root-cause classes

| # | Class | Bug shape (generic) | Commits in this shape | Structural gap |
|---|-------|---------------------|-----------------------|----------------|
| **A** | **Modal input contract** | A modal overlay is drawn, but the input layer doesn't *own* the keyboard/mouse while it's up. Unhandled keys fall through to the locked-but-receptive composer / fire orthogonal shortcuts behind the overlay; the modal's own buttons are shadowed by a base-layer click/drag region, so clicks never reach them. To the operator the modal looks dead. | recovery-modal keyboard-leak whitelist; resume-scroll + approval-modal Tab/mouse; dialog-only approval + modal-button click-shadow fix | No single "a modal must intercept-whitelist + capture mouse" contract. Each modal re-derived (or forgot) the routing rules ad hoc. |
| **B** | **Blocking IO on the UI thread** | A synchronous subprocess / git / clipboard call sits inside a `dispatchMsg` message handler. While it blocks (git lock contention, PowerShell spin-up), the Elm event loop stalls: no keys, no `TickMsg`, no animation, no log writes. Indistinguishable from a crash. | "move blocking subprocess calls off the UI thread" (4 sites fixed, 1 explicitly deferred) | No rule that *all* IO leaves a handler via a `Future`/`Cmd`; no mechanical check. Compliance is per-author memory. |
| **C** | **Feature must update every surface** | New model state ships with the behaviour wired but one or more *advertising / driving* surfaces stale: footer never names the keybind, palette/help/keymap/testdriver tokens not updated. The capability exists but is invisible or undiscoverable. | footer never advertised copy-on-selection; tool-use chunk added state but the chat/heartbeat split was wrong | No checklist/test that ties a model field or `AppMsg` case to the full surface set it implies. |
| **D** | **Operator visibility — "looks frozen"** | Two different failures (frozen loop; silent spawn / `stderr` failure) present identically: *nothing is happening*. The operator cannot tell working from stuck from failed. | move blocking calls off UI thread (frozen loop); durable `spawn_failure` / `stderr` logging (silent failure) | No always-on, single signal that monotonically distinguishes working / stuck / failed. Error state lived only in transient toasts. |

The throughline: **state changed; a contractually-coupled surface did
not.** A → input-routing surface. B → the "this work runs off-thread"
surface. C → the discovery surfaces. D → the liveness surface.

---

## Structural fixes

### Class A — the modal input contract

**The defect, precisely.** `dispatchMsg` gates two interceptors before the
main `match` (`app/ui/update.gala:522-552`): `recoveryIntercept`
(`app/ui/update.gala:652`) when `m.Recovery.IsDefined()`, and
`approvalIntercept` (`app/ui/update.gala:707`) when `State == Approval(_)`.
Both shipped originally returning `None` for everything they didn't
explicitly handle — i.e. **blacklist by accident**: any key they didn't
name fell through to the composer / global shortcuts behind the overlay.
The recovery modal looked dead because typed runes silently landed in the
locked composer. Separately, the modals' `ButtonClick` widgets were
unreachable by mouse: the conversation pane registers a per-entry drag
region that tiles the whole centre pane, and gala-tui's click resolver
checks drag regions before click regions on a fresh press, so a press on a
centered modal button resolved to a conversation drag. The fix added
`modalCapturesMouse` (`app/ui/view.gala:355`) and made `View`
(`app/ui/view.gala:81-86`) and `conversationPanel`
(`app/ui/view.gala:1521`) drop the base-layer interactive regions while a
capturing modal is up.

Both halves were applied *per modal, by hand, after a field report*.
Nothing stops modal #3 from repeating either half.

**Enforced rule.** Every modal overlay is defined by a single record, and
the runtime — not the modal author — wires routing:

```
struct ModalSpec(
    Name            string,                       // "recovery", "approval"
    IsUp            (AppModel) => bool,            // when this modal owns input
    Handled         (AppModel, AppMsg) => Option[Tuple[AppModel, Cmd[AppMsg]]],
    PassThrough     (AppMsg) => bool,              // Esc / Quit / this modal's own clicks
    CapturesMouse   bool,                          // has clickable controls
)
```

1. **Whitelist by construction.** `dispatchMsg` consults the active
   `ModalSpec`. Order: `Handled` → if `Some`, done. Else `PassThrough(msg)`
   → fall to main dispatch. **Else swallow** (`(m, NoCmd)`), unconditionally.
   The default is *swallow*, not *fall through*. A modal author can never
   again leave a leak by omission, because there is no "rest" arm that
   reaches the composer.
2. **Mouse capture is derived, not hand-coded.** `modalCapturesMouse`
   becomes `activeModal(m).Map(_.CapturesMouse).GetOrElse(false)`. `View`
   and `conversationPanel` already key off this one predicate; new modals
   opt in via the bool, not by editing `View`.
3. **One registry.** `allModals : Array[ModalSpec]`. `activeModal(m)` =
   `allModals.Find(_.IsUp(m))`. Adding a modal = appending one entry; the
   intercept and z-order behaviour come for free.

**Test template** (pins the contract for *every* registered modal — a new
modal added to `allModals` is automatically covered or the suite fails):

```gala
import . "martianoff/gala/test"

// Every modal must swallow composer-bound input by default. Drives
// the regression that the recovery whitelist fixed, generically.
func TestModalContract_NoKeyLeaksToComposer(t T) T {
    return allModals().FoldLeft(t, (acc, spec) => {
        val m  = modalUpFixture(spec)                 // spec.IsUp(m) == true
        val (m2, _) = Update(m, KeyChar('x'))
        val a1 = Eq(acc, m2.Composer, m.Composer)     // composer untouched
        // a non-passthrough global shortcut must NOT fire behind it
        val (m3, _) = Update(m, KeyMerge())
        Eq(a1, stateTag(m3.State), stateTag(m.State))
    })
}

// Every mouse-capturing modal must drop base-layer regions so its
// buttons are reachable. Pins the click-shadow class.
func TestModalContract_CapturingModalSuppressesBase(t T) T {
    return allModals().Filter(_.CapturesMouse).FoldLeft(t, (acc, spec) => {
        val m = modalUpFixture(spec)
        IsTrue(acc, modalCapturesMouse(m))            // single predicate
    })
}

// Esc and Quit always pass through (modal stays dismissable/quittable).
func TestModalContract_EscAndQuitAlwaysPassThrough(t T) T {
    return allModals().FoldLeft(t, (acc, spec) => {
        val a = IsTrue(acc, spec.PassThrough(HistoryDeselect()))
        IsTrue(a, spec.PassThrough(QuitMsg()))
    })
}
```

Because the tests fold over `allModals()`, the prevention is *structural*:
you cannot register a modal without satisfying the contract, and you
cannot add a modal outside the registry without losing its intercept
entirely (so it visibly fails its own behaviour tests).

**Effort: M.** The two existing modals already implement both halves; this
is a refactor to a registry + three fold-tests, no behaviour change.

---

### Class B — no blocking call in a message handler

**The defect, precisely.** The off-thread sweep split four handlers into
an entry-point returning `FutureCmd[AppMsg](Fut = concurrent.FutureApply…)`
plus a result-message handler:

- clipboard read → `onPasteClipboard` (`app/ui/update.gala:1354`)
- QA-gate manifest → `qaPromptReadyCmd` (`app/ui/update.gala:3643`),
  which wraps `buildQAReviewPrompt` → `gitFilesList`
  (`app/ui/update.gala:3820`, subprocess at `:3827`)
- engineer commit-gate → `uncommittedCheckCmd` (`app/ui/update.gala:2472`)
- approval / TL-summary PR-readiness → `approvalReadyCmd`
  (`app/ui/update.gala:4795`) and `summaryReadyCmd` (`:4856`), wrapping
  `checkPrReady` (`app/ui/update.gala:5068`, git subprocess at `:5073`/`:5124`)

**Remaining synchronous IO reachable from `update` (the rule's targets):**

1. **The explicitly-deferred site — `ensureSession` → `EnsureWorkspace`.**
   `ensureSession` (`app/ui/update.gala:1987`) calls `EnsureWorkspace`
   (`app/runtime/runtime_glue.gala:137`) synchronously, which for the lead
   runs `git worktree remove --force` and `git worktree add -B`
   (`app/runtime/runtime_glue.gala:237`, `:258`) and for engineers runs the
   per-engineer worktree subprocess (`app/runtime/runtime_glue.gala:100`),
   then `SpawnSession` — all on the UI thread, inside the handler. It is
   called **directly (no `Future`)** from at least eleven handler paths:
   `app/ui/update.gala:342, 424, 1686, 1784, 2542, 2620, 3225, 3314, 3680,
   4016`, plus the user-submit path. This is the deepest residual freeze
   risk and remains open.

2. **A still-live site the sweep missed —
   `recoverApprovalIfReady`.** `recoverApprovalIfReady`
   (`app/ui/update.gala:4954`) calls `checkPrReady` **synchronously** at
   `app/ui/update.gala:4972`, and it is reachable from a handler at
   `app/ui/update.gala:778` (the post-recovery resume path). This is the
   same `git rev-list`/`git rev-parse` blocking call the sweep moved
   off-thread in the approve/summary paths, but this third caller was not
   converted. **Flagged: a currently-shipping blocking-IO-on-UI-thread
   violation** of exactly the class the sweep was meant to close — strong
   evidence the rule needs a *mechanical* check, not author vigilance.

**Enforced rule.** *No message handler reachable from `dispatchMsg` may
call a blocking primitive directly. Every subprocess / git / clipboard /
filesystem-walk call leaves the handler as a `FutureCmd` and lands its
result through a dedicated result `AppMsg`.* Blocking primitives are the
known set: `subprocess.NewSpawnOpts`/`subprocess.*`, and any function whose
transitive body reaches one (`ensureSession`, `EnsureWorkspace`,
`checkPrReady`, `gitFilesList`, `hasUncommittedWork`, `readClipboard`,
`buildQAReviewPrompt`).

**Mechanical check (ranked highest leverage in §Prioritized).** A
build-time guard, cheapest first:

- *grep gate (S, ship now):* a `bazel test`-wired script that greps
  `app/ui/update.gala` for direct calls to the blocking-primitive set
  *outside* a `…Cmd`/`FutureApply` lambda body and outside the known
  result-handlers, and fails the build on a match. Seed its allowlist with
  the legitimate Future-wrapped sites; the two open sites above appear as
  the first two violations, which is the proof it works.
- *contract test (S):* for each entry-point handler, assert it returns with
  **no state mutation that depends on the IO** and a non-`NoCmd` command —
  i.e. it cannot have done the work inline:

```gala
func TestOffThread_HandlerReturnsImmediately(t T) T {
    // Entry-point must hand off, not block: model unchanged except
    // for "pending" bookkeeping, and a Cmd is returned.
    val m = qaGateFixture()
    val (m2, cmd) = spawnQAReview(m)
    val a = Eq(t, stateTag(m2.State), stateTag(m.State))   // no IO-derived state
    return IsFalse(a, isNoCmd(cmd))                        // work was deferred
}
```

The grep gate is the real prevention (catches it before review); the
contract test documents intent and catches a regression that re-inlines.

**Effort: check = S; closing the deferred `ensureSession` chain = L** (it
threads through ~11 spawn sites and changes their handler shape). The check
should land first and *flag the L work as a known violation* rather than
block on it.

---

### Class C — a feature must update every surface

**The defect, precisely.** Selection state (click-to-select, drag-to-range)
shipped with the highlight and the copy working but `footerHints`
(`app/ui/view.gala:2064`) never advertised `Ctrl+Y`; the fix added the
selection-aware branch at `app/ui/view.gala:2074-2084`. The tool-use chunk
added `IsToolActivity` to `ClaudeChunk` but the first cut surfaced it as
per-tool chat spam instead of a silent heartbeat flip. Same shape: model
state moved, a coupled surface didn't.

**The full surface set a user-visible feature must touch in lockstep:**

| Surface | Location | Why it's load-bearing |
|---|---|---|
| model field / `AppMsg` case | `app/ui/model.gala` | the state itself |
| `dispatchMsg` arm | `app/ui/update.gala:553+` | the behaviour |
| view render | `app/ui/view.gala` `View`/panels | the operator *sees* the state |
| `footerHints` | `app/ui/view.gala:2064` | the operator learns the keybind in context |
| keymap | `app/cli/keymap.gala` | the key actually dispatches the msg |
| help overlay | `helpRows` `app/ui/view.gala:171` | discoverability out of context |
| palette | `paletteActions` `app/ui/update.gala:1261` | mouse/searchable entry |
| testdriver token | `app/testdriver/testdriver.gala:230` | the feature is E2E-drivable |

A feature is "done" only when every applicable row moved. Today nothing
ties them together.

**Enforced rule + test.** Maintain one declarative table of operator-facing
capabilities; a test asserts each is wired on every applicable surface:

```gala
struct Capability(
    Name        string,
    Msg         AppMsg,        // the dispatch it triggers
    Key         string,        // keymap chord, or "" if mouse/state-only
    InPalette   bool,
    InHelp      bool,
    FooterWhen  Option[(AppModel) => bool],   // a model state that must hint it
)

func TestCapability_EveryFeatureWiredEverySurface(t T) T {
    return capabilities().FoldLeft(t, (acc, c) => {
        val a1 = if (c.Key != "")
                     Eq(acc, ParseKey(c.Key), Some(c.Msg))      // keymap
                 else acc
        val a2 = if (c.InPalette)
                     IsTrue(a1, paletteActions(model0()).Exists(_.Msg == c.Msg))
                 else a1
        val a3 = if (c.InHelp)
                     IsTrue(a2, helpRows().Exists(_.Contains(c.Key)))
                 else a2
        c.FooterWhen match {
            case Some(pred) => Contains(a3, footerHints(forceState(model0(), pred)), c.Key)
            case None()     => a3
        }
    })
}
```

Adding a feature without appending its `Capability` row is allowed — but
then the *behaviour* test for it fails (the key never dispatches). Adding
the row but skipping a surface fails *this* test with the exact missing
surface named. Either way the gap is mechanical, not reviewer-spotted.

**Effort: M.** The table is ~20 rows of existing capabilities; the test is
straightforward folds over already-pure functions (`paletteActions`,
`helpRows`, `footerHints` are all pure of `AppModel`).

---

### Class D — the always-on liveness signal

**The defect, precisely.** A frozen event loop (Class B) and a silent
spawn / `stderr` failure both render as *nothing happening*. The fix for
the silent-failure half added durable `spawn_failure` and `stderr` events
(`app/runtime/debuglog.gala`, fired from every `ensureSession`-Left site
and from `onStderr` before the toast branch). The tool-use fix kept the
heartbeat ticking during long silent tool runs by flipping status to
`StWorking` on an `IsToolActivity` chunk *without* a chat line. Both are
correct but partial: error state still lives primarily in transient
toasts/`LastError`, and "is the loop even alive" has no dedicated surface
distinct from "a member is working".

**Enforced rule — three orthogonal always-on signals, never collapsed:**

1. **Loop liveness.** A header indicator driven *only* by `TickMsg`
   cadence (last tick age), independent of any member status. If ticks stop
   landing, this freezes visibly — the one thing that distinguishes a
   frozen loop from an idle-but-alive app. This is the missing signal: the
   freeze class had *no* surface that a stalled loop could not also fake.
2. **Work liveness.** The existing per-member heartbeat (`LastChunkAt` →
   StWorking/Slow/Stuck), which the tool-use fix already keeps honest
   during silent tool runs.
3. **Failure surfacing.** Already durable in `events.jsonl`
   (`spawn_failure`, `stderr`); the rule is that *every* terminal error
   path writes a durable event **before** the transient toast, so a
   post-hoc replay always explains a silent member. Extend the same
   discipline to any new "returned Left / dropped silently" path.

The invariant: *at any instant the operator can read off (loop alive?) ×
(work progressing?) × (last failure, if any) from always-present surfaces —
never from a toast that may have expired.*

**Test template:**

```gala
// Loop-liveness indicator must reflect tick starvation, and must
// NOT be satisfied merely because a member is StWorking.
func TestLiveness_LoopIndicatorIndependentOfMemberStatus(t T) T {
    val working = setStatus(model0(), "Eng", StWorking())
    val stale   = working.Copy(LastTickAt = longAgo())
    return Contains(t, headerWidgetText(stale), "stalled")   // freeze is visible
}

// Every spawn-failure path emits a durable event before the toast.
func TestLiveness_SpawnFailureIsDurableNotJustToast(t T) T {
    val (_, _) = withDebugRepo(() => Update(failingSpawnModel(), KeySubmit()))
    return IsTrue(t, eventsJsonl().Exists(_.Kind == "spawn_failure"))
}
```

**Effort: S–M.** Failure-durability is largely in place (assert it, extend
to new paths). The loop-liveness header indicator is the only net-new
surface — one model field (`LastTickAt`), one header cell, one test.

---

## Prioritized recommendations

Ranked by **impact × inverse effort** — cheapest mechanism that retires the
most operator-visible failure first. (This is the answer to "the cheapest
pre-merge mechanism that would have caught it" per class.)

| Rank | Mechanism | Class | Effort | Impact | Why first |
|---|---|---|---|---|---|
| **1** | **Blocking-IO grep gate** wired into `bazel test` | B | **S** | **High** | Pure-text check, no refactor. Would have caught all four fixed sites *and* the still-live `recoverApprovalIfReady → checkPrReady` (`app/ui/update.gala:4972`) and the deferred `ensureSession` chain — at review time, every time. Freeze-class bugs read as crashes; preventing one is worth the most per unit effort. |
| **2** | **Modal contract registry + 3 fold-tests** | A | M | High | Three separate field reports ("modal dead", "buttons don't click", "no Tab") were one missing contract. The fold-over-`allModals` test makes modal #3 impossible to ship leaky. Highest *recurrence* class — same shape hit three times. |
| **3** | **Capability table + every-surface test** | C | M | Med-High | Turns "did you remember the footer/palette/help/keymap?" from a review checklist (which already failed twice) into a mechanical fail naming the missing surface. |
| **4** | **Loop-liveness header indicator + durability assertions** | D | S–M | Med | Failure-durability mostly exists; the net-new piece (tick-starvation indicator) is small and is the *only* signal that separates a frozen loop from an idle app — the single highest-confusion operator state. |
| **5** | **`capTitleAtWordBoundary` boundary-inclusive + property test** | (B-adjacent / artifact) | S | Low-Med | The mid-word-cut-in-backtick PR-title bug (inclusive `i >= rollbackFloor`, `app/runtime/runtime_glue.gala`) is a boundary-condition family: a property test asserting "output never ends inside an unbalanced backtick and never exceeds cap" generalises past the one input. Cheap, narrow blast radius, so last. |

**Sequencing.** #1 ships this week and immediately flags #2's deferred work
and the missed `recoverApprovalIfReady` site as known violations (the gate
proves itself). #2 and #3 are the two M-effort registry/table refactors
that convert reviewer-vigilance into compile/test-time enforcement and kill
the two highest-recurrence classes. #4 closes the perceptual gap that makes
B and silent-failure bugs *look* identical. #5 is a self-contained boundary
hardening.

**One-line summary of the whole audit:** every bug in the set is *model
state that changed without its contractually-coupled surface moving with
it*. The fix is not nine careful reviews — it is four registries/gates that
make the coupling mechanical: a modal registry (A), an IO-off-thread gate
(B), a capability table (C), and an always-on liveness triple (D).
