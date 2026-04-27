module github.com/martianoff/gala_team

gala 0.37.0

require (
    github.com/martianoff/gala-tui v0.0.0
)

// Local override during development — swap to a tagged version after release.
replace github.com/martianoff/gala-tui => ../gala_tui
