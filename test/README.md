# Golden-config test tree

A sibling environment for the parent `Makefile`. Holds a frozen set of
service fixtures and the rendered output they should produce
(`config/`, checked in). `make test` from the parent renders the
fixtures with the just-built binaries and `git diff`s the result —
any unintended change in render behavior shows up as a golden diff.

## How it satisfies the parent Makefile

The parent's `Makefile` is symlinked in (`Makefile -> ../Makefile`),
so the same rules run here. Every path those rules reference exists
in this directory, but most are pass-throughs to the parent:

| Path                    | Kind     | Notes                                                    |
|-------------------------|----------|----------------------------------------------------------|
| `Makefile`              | symlink  | The shared rules.                                        |
| `lisp/`                 | symlink  | Shared source. Resolves `lisp/mediaserver.asd`, `lisp/qlfile.lock`, `lisp/.qlot/` for the parent rules. |
| `targets/`              | symlink  | Shared deploy templates.                                 |
| `script/build.sh`       | **real** | Symlink shim — see below.                                |
| `bin/`                  | **real** | Populated by `script/build.sh` (symlinks back to parent).|
| `services/`, `globals.yml`, `config.local.yml` | **real** | Test fixtures. |
| `config/`               | **real** | Golden output, checked in.                               |
| `Makefile.local`        | **real** | Local `TARGET=…` override; kept minimal here.            |

`test/script/build.sh` does *not* compile a binary. It runs
`ln -sf ../../bin/$NAME bin/$NAME` — the test tree always uses the
binary the parent just built, so golden output reflects the same
SBCL build a deploy would use. The `lisp/.qlot/installed.stamp`
dependency on `bin/%` is satisfied by the parent's stamp via the
`lisp/` symlink, so no qlot install ever runs from inside `test/`.

## Running order

`make` from the parent handles ordering. Direct invocation:

- **`make test` (parent)** — builds `bin/build-service-config` and
  `bin/render`, then `cd test && make all`. Always safe.
- **`cd test && make all`** — only valid *after* the parent's
  `bin/*` exists. Otherwise `script/build.sh`'s `ln -sf` creates a
  dangling symlink and the render step fails when Make tries to exec
  it. If you're iterating on render code, run `make bin/render`
  (or `make all`) at the parent first, then `make all` here is a
  fast render + diff loop.

If you ever see `bin/render: No such file or directory` from inside
`test/`, the parent binary doesn't exist yet — build it from the
parent root first.
