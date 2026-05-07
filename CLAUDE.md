# gala-team — Claude Code instructions

## NEVER commit private artifacts

These categories MUST NOT appear anywhere in the source tree (code, comments, tests, docs, scripts, fixtures, README). The repo is public; readers don't share our working environment, our git history, or our local debug logs.

### Forbidden patterns

| Pattern | Why | Replace with |
|---|---|---|
| `C:\Users\<name>\...`, `/home/<name>/...`, any absolute path containing a real username | Leaks the maintainer's home directory layout. Breaks portability. | Generic placeholders: `/workdir/...`, `<repo>/...`, or use `os.tmpdir()` / `process.env.TEMP` / `$HOME`. |
| Personal usernames or GitHub handles anywhere except published repo URLs | Same as above. | Drop entirely or use `<user>`. |
| Audit-log dates referencing local debug runs (`2026-05-07 audit captured…`, `the 2026-05-04 log audit caught…`) | These reference local sessions readers can't see. | Describe the bug shape directly: "Past audits captured…", "An earlier version of this code…", "Observed in past sessions…". The substantive description of the bug stays; the date and "audit" provenance go. |
| Specific PR numbers in comments (`PR #333`, `PR #327`) | Means nothing to outside readers; rots when PRs are squash-merged or repo is forked. | Drop. Describe the bug; the git blame + commit message links to the PR if anyone needs it. |
| Specific commit SHAs in comments (`commit 221fecf`, `cb26777`) | Same as PR numbers. | Drop. |
| References to private docs (`docs/private/...`, internal wiki URLs, GitHub private comment URLs) | The directory is gitignored — readers can't open the file. | Drop, or move the substantive content inline into the source comment / public docs. |
| Real session IDs, claude session IDs, real GitHub issue / discussion IDs | Leaks operational data. | Use placeholders (`<session-id>`, `00000000-0000-0000-0000-000000000000`). |

### What CAN go in comments

- The substantive bug description ("Without this, a TL stream that emits two identical chunks would dispatch each engineer twice" — keeps the why without naming the specific session).
- Public design / spec references (RFC numbers, links to public Go stdlib docs, links to public API references).
- Public PR / commit links **in commit messages** (Co-Authored-By, etc.) — those go in `git log` only, not in source files.

### Why this matters

The user has been bitten by leaking these into public-facing surfaces (PR descriptions, README, source comments). The orchestrator already enforces some of these via `validatePrBody` (catches `.gala_team`, member names, orchestration vocabulary in `@summary` bodies); the same standards apply to anything we check into the repo by hand.

When in doubt: read the comment back as if you'd never seen this codebase. Does every reference resolve? Does every path / number / date make sense to a stranger? If not, drop or rewrite.

## Other conventions

- **Testing on Windows**: when `bazel test` fails with `__COMPAT_LAYER` / `requires elevation` for `*_test.exe`, run the binary directly with `__COMPAT_LAYER=RUNASINVOKER` set. The test binary itself works; only Windows's "this looks like an installer" heuristic blocks the bazel runner.
- **Internal-package tests** (`package <name>` matching the lib package): the BUILD `gala_go_test` target needs `pkg = "<name>"` + `lib_srcs = [...]` listing every source file from the lib. Without that, the test binary can't see the lib's symbols and fails with `undefined: <Symbol>` errors.
