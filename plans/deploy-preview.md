# Deploy preview

`make preview` shows what `make install` would change on the target,
before any rsync runs. Terminal-only output — never written to the
repo, since real configs may carry sensitive values.

## Goal

A single `make preview` verb that, against whatever `TARGET` is
currently set:

1. Lists which files would be added or changed under
   `/opt/mediaserver/config/` (manifest).
2. Shows the actual content diff for those files (review).

Empty output = "install is a no-op." Non-empty = "here's exactly what
would change." That's the contract.

## Context

Extracted from `plans/pre-rewrite.md` (Part 2) now that
`plans/remote-deploy.md` has shipped. With `TARGET`/`RSYNC_DEST`/
`REMOTE` in place, preview can compose with both local and remote
deploys uniformly instead of being laptop-only.

Primary near-term use: low-risk pre-flight on every fatlaptop deploy
("did I render what I think I rendered?"). Medium-term use: cutover
gate during the eventual Lisp rewrite of `render.rb` — render with
both implementations, diff the trees, ship when the diff is empty.

## Related plans

- `plans/remote-deploy.md` — **shipped**. Provides `TARGET`,
  `RSYNC_DEST`, `REMOTE`. This plan consumes them.
- `plans/pre-rewrite.md` — sibling. Was the original home of this
  work; goldens stay there. The two plans share zero code; they can
  land in either order.
- `plans/nixos-target.md` — preview semantics shift under NixOS
  (`nixos-rebuild dry-activate`, `nvd diff`). The rsync-and-diff form
  here is medium-term scaffolding, not a permanent fixture. Keep
  the implementation small for that reason — don't grow ergonomics
  expecting it to outlive the Debian target.
- `plans/static-uids.md` — no interaction. Preview operates on
  rendered file contents, not on filesystem ownership.

## Design notes

**Match `make install`'s rsync semantics exactly.** Today's install
rsync uses per-service `rsync -a --no-owner --no-group
--chown=<svc>:mediaserver --chmod=Dg+s` with no `--delete`. Preview
must mirror that: deployed-only files (sqlite DBs, runtime state apps
write into their config dirs) are **not** flagged "to delete." Use
`rsync -ain` (no `--delete`) so the manifest reflects what install
would actually do.

**Drive the content diff from the rsync changed-file list, not a
bidirectional `diff -ruN` over the whole tree.** A blind tree diff
floods output with runtime-state files install would never touch.
Iterate the rsync `--out-format` lines, and for each changed file,
show its diff.

**Snapshot the remote tree to `tmp/`.** `diff` can't reach across
ssh. First step on a remote target: `$(REMOTE) tar -C
/opt/mediaserver/config -cf - <changed-files> | tar -C
tmp/deployed-snapshot -xf -`. `tmp/` is gitignored. Only snapshot the
files rsync flagged — no point pulling the whole runtime state across
the wire just to ignore it.

**Local target degenerates cleanly.** With `TARGET=local`, `$(REMOTE)`
is empty; the tar round-trip becomes a local copy (or short-circuit
to a direct `diff` against `/opt/mediaserver/config/`). Either is
fine; pick whichever keeps the Makefile shorter.

**`make install` stays unchanged.** Preview is a manual pre-flight,
not a confirmation gate. Trivial changes still go straight through
`make install` from muscle memory. If that becomes a footgun later,
add a prompt then.

**Per-service rsync cost.** Install loops per service for `--chown`
reasons. Preview probably doesn't need per-service granularity for
the manifest — a single `rsync -ain` against the whole tree is
cheaper and the output is what the human reads anyway. Per-service
only matters if we want chown info in the diff, which we don't.

## Commits

1. **Add `tmp/` to `.gitignore` and `make clean`** — Preview writes
   `tmp/deployed-snapshot/` for the content diff. Make sure it can't
   accidentally land in a commit, and that `make clean` removes it
   alongside `config/`.
   *Verify:* `make clean && ls tmp/ 2>&1` shows no such directory;
   `git status` after a manual `mkdir tmp/deployed-snapshot` shows
   no untracked entry.

2. **Add local-only `make preview`** — Implement the simple form
   first, gated on `TARGET=local`: `rsync -ain` for the manifest, a
   direct `diff -ruN` against `/opt/mediaserver/config/` for content.
   Depends on `check` and `all` (render fresh before previewing).
   *Verify:* `make preview` on this laptop with no install
   underneath prints "no changes" or a sensible manifest; after
   touching one ERB and re-rendering, preview shows just that file
   in both manifest and diff.

3. **Generalize `make preview` to `$(REMOTE)`** — Snapshot the
   remote config tree to `tmp/deployed-snapshot/` via `$(REMOTE) tar
   | tar`, then diff. Drive the snapshot list from the rsync
   manifest so we only pull changed files. Local target falls
   through to the same code path with `$(REMOTE)` empty.
   *Verify:* `TARGET=fatlaptop make preview` against an unchanged
   tree prints "no changes." With a single ERB tweak, manifest +
   diff show only that file. Total ssh round-trips ≤ 2 (one
   `rsync -ain --rsync-path="sudo rsync"`, one `tar` snapshot).

4. **Document `make preview` in CLAUDE.md and README** — One-line
   entry in the commands list; brief note in the workflow section
   that `make preview` is the optional pre-flight before
   `make install`.
   *Verify:* `grep -n preview CLAUDE.md README.md` shows the
   entries; render the README locally and eyeball.

## Non-goals

- **No confirmation gate on `make install`.** Preview is opt-in;
  install does not invoke it.
- **No diff filtering / smart redaction.** Output goes to a TTY the
  user controls. If a config carries a secret, preview will show it
  — same as `cat`.
- **No `make preview-<svc>`.** If single-service preview is
  eventually wanted, add it then. The whole-tree form is small and
  fast enough that scoping isn't worth the Makefile complexity yet.
- **No persistence.** Nothing under `tmp/` is meant to be inspected
  later; `make clean` wipes it. If "what did I deploy last Tuesday"
  becomes a real question, that's a separate plan.

## Open questions

- **Does `rsync -ain --rsync-path="sudo rsync"` work cleanly?**
  Dry-run mode plus sudo-on-target is the unusual combination.
  Should — `-n` is honored regardless of the rsync path — but worth
  confirming on the first remote run.
- **`certs/` rsync.** Install also rsyncs `certs/` separately. Does
  preview cover it? Probably yes (same one-line `rsync -ain`); just
  needs to not get forgotten.
- **Output volume on first run after a render churn.** If preview
  follows a big template change, the content diff could be hundreds
  of lines. Acceptable — pipe to `less`. Don't auto-page.
