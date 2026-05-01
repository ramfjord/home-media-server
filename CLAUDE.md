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
