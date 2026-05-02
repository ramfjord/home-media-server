# CLAUDE.md

@README.md
@CONTRIBUTING.md

## Doc split

- **README.md** — facts about the project (what it is, services, networking, getting-started, deploy target). Front door for humans evaluating the repo.
- **CONTRIBUTING.md** — conventions for *changing* the project (template style, field access, debugging shortcuts, make targets).
- **CLAUDE.md** (this file) — agent-behavior signals only. Instructions about how to act, not facts about the codebase.

Both README.md and CONTRIBUTING.md are imported above and load into every session, so be stingy with what goes in them — verbose-but-rarely-relevant material belongs under `docs/` and should be linked, not imported.

## Keeping docs current

When a change affects content owned by one of these docs, update that doc in the same commit:

- New/removed/renamed service, port shift, setup-step change, deploy mechanic → **README.md**
- New template convention, field-access change, debugging shortcut, make-target change → **CONTRIBUTING.md**
- New agent-behavior expectation, or a change to the split rule itself → **CLAUDE.md**

If a fact is load-bearing for both audiences (humans and agents), keep it in README.md or CONTRIBUTING.md — don't restate it here. CLAUDE.md should not duplicate facts that the imported docs already cover.

## Bumping elp (or any qlot dep): `qlot update <name>`

All Lisp state lives under `lisp/` (the `.asd`, `qlfile`, `qlfile.lock`, `.qlot/`). Run qlot from there:

```sh
cd lisp && qlot update elp
```

That re-fetches the source, rewrites `lisp/qlfile.lock`, and reinstalls. The Makefile's `lisp/.qlot/installed.stamp` rule picks up the new lock on the next build automatically.

Why `lisp/` matters: qlot's default install scans the project root for `.asd` files and walks each system's transitive deps. With everything Lisp confined to `lisp/`, the walk only sees `lisp/mediaserver.asd` — fast (~2s steady-state, ~10s cold). Before the move, sibling `.asd` files (e.g. `elp/elp.asd` from a checkout) pulled in `hu.dwim.walker`'s chain and pegged multiple SBCL processes for minutes. Do not edit `qlfile.lock` by hand — let qlot manage it.

## Run make targets host-native

The dev container (`docker compose run --rm dev`) exists for users who don't want to install SBCL/qlot on their machine. Thomas works host-native — `sbcl`, `qlot`, `make` all on `PATH` — so run targets directly: `make all`, `make test`, `qlot install`, etc. Do not invoke `docker compose run --rm dev` to run a make target on Thomas's behalf; it adds latency, fights with mounted-path semantics, and (critically) running `qlot install` inside the container leaves `/workspace`-prefixed symlinks under `.qlot/dists/` that break subsequent host builds.
