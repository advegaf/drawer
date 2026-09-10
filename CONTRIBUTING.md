# Contributing

```sh
brew install xcodegen   # once
make run                # generate, build, launch a Debug build
make test               # the suite
```

Debug builds are signed with an Apple Development identity under team
`DV483F72N3`. That is deliberate rather than incidental: macOS remembers
Automation approval per signed binary, so an ad-hoc build would ask again on
every rebuild.

Two things this project holds itself to, and a change that breaks either one
is not finished:

- Every behaviour has a row in a story sheet with what it should do, whether
  it has been checked by hand or by a test, and which test checks it. The
  suite is 470 tests and they run in about forty seconds.
- Decisions that cost a measurement get the number written down beside them,
  in a comment or in the commit, rather than only the conclusion.

`make shot NAME=... ENV="DRAWER_DEMO=states ..."` captures a window. Always
with a `DRAWER_DEMO` flag: a capture without one runs against the real
preferences domain and photographs whatever the person running it has
pinned.
