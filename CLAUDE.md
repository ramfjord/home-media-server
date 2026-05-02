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

## Swank image: bootstrap from `lisp/`, symlink state to root

The `ramfjord:swank-image` skill expects a `*.asd` at the directory it bootstraps; this project's only `.asd` is `lisp/mediaserver.asd` (see the qlot-scan note above for *why*). So the image is bootstrapped from `lisp/`, and the state files are symlinked up to the worktree root so MCP and vlime pick them up when launched here:

```sh
/home/tramfjord/projects/claude-skills/skills/swank-image/bootstrap-swank.sh "$PWD/lisp"
ln -sf lisp/.swank-port    .swank-port
ln -sf lisp/.swank-session .swank-session
ln -sf lisp/.mcp.json      .mcp.json
[ -f lisp/.vlime-port ] && ln -sf lisp/.vlime-port .vlime-port  # vlime auto-connect
```

The bootstrap auto-detects `lisp/.qlot/setup.lisp` and loads it first, so `:elp` (and any other qlot-managed dep) resolves through qlot's dist rather than `~/quicklisp/`.

The image loads `:mediaserver` (which transitively loads `:elp`), so .elp templates can be parsed/compiled from the running image regardless of cwd — call into ELP with absolute paths.

Footgun: `cleanup-swank.sh "$PWD"` from the root will `rm` the symlinks but leave the real files in `lisp/`. Run cleanup against `"$PWD/lisp"` (or remove both sides manually).

## Run make targets host-native

The dev container (`docker compose run --rm dev`) exists for users who don't want to install SBCL/qlot on their machine. Thomas works host-native — `sbcl`, `qlot`, `make` all on `PATH` — so run targets directly: `make all`, `make test`, `qlot install`, etc. Don't invoke `docker compose run --rm dev` to run a make target on Thomas's behalf; it adds container-start latency for no benefit when the host already has the toolchain.
