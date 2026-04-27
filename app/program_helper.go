package app

import (
	galatui "github.com/martianoff/gala-tui"
	"martianoff/gala/std"
)

// NewTUIProgram constructs a gala_tui.Program with the necessary
// std.Immutable wrapping. Workaround for transpiler Issue 3 (cross-module
// struct named-arg constructor not lowering through .Apply()) — see
// gala_simple/docs/private/TRANSPILER_BUG_GALA_TUI_CROSSMODULE.md.
//
// Once the transpiler fix lands, GALA callers can replace
//
//	val p = NewTUIProgram[Model, Msg](initial, update, view)
//
// with the natural form
//
//	val p = Program[Model, Msg](Initial = initial, Update = update, View = view)
//
// and this helper can be deleted.
func NewTUIProgram[M, T any](
	initial M,
	update func(M, T) std.Tuple[M, galatui.Cmd[T]],
	view func(M) galatui.Widget,
) galatui.Program[M, T] {
	return galatui.Program[M, T]{
		Initial: std.NewImmutable(initial),
		Update:  std.NewImmutable(update),
		View:    std.NewImmutable(view),
	}
}
