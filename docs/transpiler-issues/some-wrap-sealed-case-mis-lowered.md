# `Some[T](Case(...))` mis-lowered to bare struct literal in the same package

## Summary

In a package that defines a sealed type and constructs case values inside
`Some[T](Case(namedArgs...))`, the transpiler sometimes lowers the
constructor call to a bare struct literal — `Some[T]{}.Apply(Case{})` —
dropping both the `.Apply(...)` method call **and** the constructor
arguments. The generated Go then fails to compile because `Case{}` (a
zero-value struct) is not assignable to the sealed interface `T`. The
defect is non-local: adding a new source file to the package can flip
the lowering of unchanged constructs in *other* files in the same
package from correct to broken.

## Environment

- Bazel: `bazel 8.0.0`
- GALA module: `1.0.0` (Bazel `bazel_dep(name = "gala", version = "1.0.0")`)
- OS: Windows 11 (10.0.26200)
- Toolchain glue: `rules_go` via the `gala` Bazel module; `gala_library`
  + `gala_go_test` macros generate per-source `_N.gen.go` files and
  hand them to `GoCompilePkg`.

## Failing constructs (observed)

Inside a package `pkg_a`, the function below is meant to wrap each case
of a sealed type `T` in `Some[T]`. The sealed type has eight cases of
varied arity; only four mis-lower (B, C, D, F). The other four (A, E,
G, H) lower correctly under identical conditions.

```gala
// In pkg_a/wrap.gala
package pkg_a

import (
    . "martianoff/gala/std"
    . "martianoff/gala/collection_immutable"
)

func wrap(tag string, x string) Option[T] {
    if (tag == "a") { return Some[T](A(P = x, Q = x)) }                              // OK
    if (tag == "b") { return Some[T](B(P = x, Q = None[string](), R = x)) }          // BROKEN
    if (tag == "c") { return Some[T](C(P = x)) }                                     // BROKEN
    if (tag == "d") { return Some[T](D(P = x)) }                                     // BROKEN
    if (tag == "e") { return Some[T](E(P = x)) }                                     // OK
    if (tag == "f") { return Some[T](F(P = x)) }                                     // BROKEN
    if (tag == "g") { return Some[T](G(P = x)) }                                     // OK
    if (tag == "h") { return Some[T](H(P = EmptyArray[string]())) }                  // OK
    return None[T]()
}
```

`T` is declared in a sibling source file in the same package:

```gala
// In pkg_a/types.gala
sealed type T {
    case A(P string, Q string)
    case B(P string, Q Option[string], R string)
    case C(P string)
    case D(P string)
    case E(P string)
    case F(P string)
    case G(P string)
    case H(P Array[string])
}
```

Note that C, D, E, F are structurally identical (one `string` field
named `P`) but only C, D, F mis-lower — E lowers correctly. The trigger
is therefore not arity, field type, or field name in isolation. See
*Scope notes* below for the strongest correlation observed.

## Correctly-lowering constructs (contrast)

The Go that `gala_library` emits for the working branches:

```go
// pkg_a/wrap_0.gen.go — case "a"
return Some[T]{}.Apply(A{}.Apply(x.Get(), x.Get()))

// pkg_a/wrap_0.gen.go — case "e"
return Some[T]{}.Apply(E{}.Apply(x.Get()))

// pkg_a/wrap_0.gen.go — case "g"
return Some[T]{}.Apply(G{}.Apply(x.Get()))

// pkg_a/wrap_0.gen.go — case "h"
return Some[T]{}.Apply(H{}.Apply(EmptyArray[string]()))
```

The constructor `Case{}.Apply(...)` is the expected method call form
(`Apply` is the generated factory on the case struct; calling it
returns a value typed as the sealed interface `T`, which `Some[T]`
accepts).

## Observed lowering (broken)

For B, C, D, F the same `Some[T](Case(...))` pattern lowers to:

```go
// pkg_a/wrap_0.gen.go — case "b"
return Some[T]{}.Apply(B{})

// pkg_a/wrap_0.gen.go — case "c"
return Some[T]{}.Apply(C{})

// pkg_a/wrap_0.gen.go — case "d"
return Some[T]{}.Apply(D{})

// pkg_a/wrap_0.gen.go — case "f"
return Some[T]{}.Apply(F{})
```

The `.Apply(args...)` call is gone and the arguments are dropped on
the floor. The Go compiler then rejects:

```
cannot use B{} (value of struct type B) as T value in argument to Some[T]{}.Apply
cannot use C{} (value of struct type C) as T value in argument to Some[T]{}.Apply
cannot use D{} (value of struct type D) as T value in argument to Some[T]{}.Apply
cannot use F{} (value of struct type F) as T value in argument to Some[T]{}.Apply
```

`B{}` / `C{}` / `D{}` / `F{}` are zero-value struct literals that have
not been promoted to the sealed-interface type, so the generic
`Some[T]{}.Apply(...)` rejects them.

## Non-local symptom (load-bearing observation)

This is the diagnostic the maintainer should weigh most heavily.

The package `pkg_a` originally contained only `types.gala` and a
second source file `legacy.gala` with its own use of
`Some[T](Case(...))` constructs that lowered correctly. The package
built green.

Adding a **third** file `wrap.gala` (the function shown above) to the
same `gala_library` caused the **unchanged** constructs in
`legacy.gala` to switch from correctly-lowering to broken in the same
package compile — the same four cases (B, C, D, F) regressed there
too. Removing `wrap.gala` restored `legacy.gala`'s green lowering
without touching it.

This says the defect is not in the lowering of any single call site
but in something the transpiler computes per-package (a generic
instantiation table, a case-method registration, or an
upcast-insertion pass) that flips polarity when the new file is in
scope. Searching for "what changed across the package boundary" is
likely a more fruitful starting point than studying one call site.

## Minimal repro steps

A trimmed copy of `pkg_a` is included alongside this report as a
sibling-split pair (`./some-wrap-sealed-case-mis-lowered/types.gala`
and `.../wrap.gala`) — the split mirrors the observed trigger
conditions, where the sealed-type declaration and the
`Some[T](Case(...))` constructions always lived in different source
files of the same package. From a fresh checkout of a Bazel module
that depends on the `gala` module
(`bazel_dep(name = "gala", version = "1.0.0")`):

1. Place `types.gala` and `wrap.gala` together in a package directory
   (`pkg_a/`) wired by a single `gala_library` target whose `srcs`
   includes both.
2. `bazel build //path/to/pkg_a:pkg_a` — observe the `GoCompilePkg`
   failure with four `cannot use X{} ... as T value` errors (for
   cases B, C, D, F).
3. Inspect the generated Go under
   `bazel-out/.../bin/path/to/pkg_a/pkg_a_<N>.gen.go` and confirm the
   bare struct literals on the broken branches versus
   `Case{}.Apply(args...)` on the working branches (A, E, G, H).

## Optional diagnostics

These probe the non-local trigger and the narrowing axes; they are
not required to reproduce the failure.

- Delete `wrap.gala`, leaving the package with only `types.gala` plus
  any sibling file that already used the same construct. Confirm the
  build goes green, then re-add `wrap.gala` and confirm the sibling
  file's untouched constructs regress.
- Collapse `types.gala` and `wrap.gala` into a single source file in
  the same package. The observed scenario always had them split;
  whether a single-file form still triggers is unknown.
- Drop case H (the only case carrying an `Array[string]` field) and
  the `collection_immutable` import. The remaining seven cases still
  exhibit the broken set {B, C, D, F} versus working set {A, E, G}.
  Further trimming to the four-case subset {C, D, E, F} preserves
  the strongest single-axis diagnostic: those four cases are
  structurally identical (one `string` field `P`), yet C, D, F mis-
  lower while E does not.

## Scope notes

What's known:

- The defect reproduces with the exact toolchain versions above.
- The eight-case sealed type used in the observed scenario was
  imported into the failing file's compile alongside another sibling
  package that defined a smaller sealed type whose case names
  partially **overlap** with `T`'s cases (different arity — the
  sibling's cases are all zero-arg). The four cases that mis-lower in
  `T` are exactly four of the cases whose names also appear in the
  sibling sealed type. A fifth same-named case (`A`) lowers correctly
  despite the name overlap. The correlation is suggestive but
  incomplete; it should not be taken as the full trigger.
- The broken cases all use **named** constructor arguments
  (`Case(P = ..., Q = ...)`). The repro has not yet been narrowed to
  test positional-only constructor arguments, but every working case
  in the observed scenario also used named arguments, so named
  arguments alone are not the trigger.

What's unknown:

- Whether a strictly single-file repro (one `.gala` source containing
  both the sealed type and the `wrap` function) is sufficient, or
  whether the multi-file split is required. The observed scenario
  always had the sealed type in a sibling file.
- Whether the sibling-package case-name overlap is required, a
  contributing factor, or coincidental. A clean test would compile
  the repro file without the cross-package import and check whether
  the same four cases still mis-lower.
- Whether the four failing cases are stable across reorderings of the
  sealed-type declaration. Permuting the case order in `types.gala`
  may reveal whether the defect tracks **declaration position** or
  **case name**.
- The relevant transpiler internals (which pass emits the
  `Case{}.Apply(args...)` call, and what state it consults
  per-package). A maintainer can likely pinpoint this faster than a
  downstream user.

The repro file is structured to make these axes easy to flip.
