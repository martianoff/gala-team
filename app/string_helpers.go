package app

// String-slicing helpers.  GALA's parser doesn't accept the `s[from:to]`
// syntax for strings (or `s[from:]` / `s[:to]`), so any GALA file that
// needs sub-string operations must call through these one-liners.  Same
// pattern as gala_simple/json/byte_utils.go.

func substring(s string, from, to int) string { return s[from:to] }
func substringFrom(s string, from int) string { return s[from:] }
func substringTo(s string, to int) string     { return s[:to] }
