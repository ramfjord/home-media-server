# Minimal runtime image for the lisp binaries

A minimal docker image that ships `bin/render` + the one `.so` it
dlopens (`libyaml-0.so.2`) on a scratch (or distroless) base. Single-
project proof-of-concept of the "ko-for-CL" pattern: declare lisp
deps + C deps + entry point, get out a small reproducible image.
The point is to get hands on the pattern in this repo, see what
actually moves, and decide later whether to extract a tool from it.

## Goal

After this branch ships:

1. `make image` produces a tagged docker image
   (`mediaserver-render:latest`) containing just `bin/render` +
   `libyaml-0.so.2` (and whatever runtime libc bits are needed).
   Image size in the ballpark of ~80MB (the binary dominates).
2. `docker run --rm -v $(pwd):/work -w /work mediaserver-render
   --service prometheus services/prometheus/prometheus.yml.elp`
   produces byte-identical output to the host-built `bin/render`
   on the same template.
3. The build is reproducible — same source tree → same image
   contents (modulo timestamps), with layer caching that does the
   right thing on dep changes vs source changes.
4. The existing build sandbox (`script/Dockerfile`,
   `script/build.sh`) is unchanged. The runtime-image build is a
   *parallel* path, not a rewrite of the development workflow.

## Context

Comes out of a long thread (2026-04-30) that ended with the build
moved into a docker container — `script/build.sh` runs
`docker run --rm sbcl …` and produces native ELFs that run on the
host. The host needs no SBCL. Libyaml is still required on the host.

This plan extends that by adding a *second* output: a minimal
runtime image. Whoever wants to run `render` can `docker run` it
without installing anything (not even libyaml). That's the value.

The bigger frame — a reusable "ko-for-CL" tool that takes
`(base_image, c-deps, lisp-deps, entry-point) → small image` — is
explicitly **not** scoped here. We do this once, manually, in this
repo. If the pattern feels good and the variables are obvious, the
extraction can happen as its own plan with concrete evidence behind
it. Building the abstraction first is exactly the failure mode
this plan is structured to avoid.

## Related plans

- `plans/lisp-render.md` — **shipped**. Provides `bin/render` and
  the SBCL build infra. This plan strictly depends on that.
- `plans/target-dirs.md` — **shipped**. Renderer's input/output
  layout. Unaffected here.
- The "switch build to docker" change (uncommitted as of
  2026-04-30) is a *precondition*: it adds `script/Dockerfile` +
  `script/build.sh` that this plan extends. Not yet a plan of its
  own — just in flight. This plan should land after that commit.

Not related (cross-checked 2026-04-30 to save the next drafter
the same thought):

- `plans/nixos-target.md` — different layer. NixOS work changes
  what the renderer *outputs* and how the rendered stack runs on
  a host. This plan changes who can run the renderer in the
  first place. Same `services.yml` input, different downstream
  concerns. They could ship in either order with no interaction.

## Design notes

**Two parallel pipelines, not a unification.** The development
workflow (`make all` → bind-mount + `docker run --rm sbcl`) stays
exactly as it is. It's fast and the user just spent a thread
simplifying it. The runtime-image build is a *separate* `docker
build` that COPYs source into the image and produces a packaged
artifact. Don't fold them together — they optimise for different
things (iteration speed vs reproducible artifact).

**Why a second Dockerfile vs a multi-stage script/Dockerfile.**
Tempting to multi-stage `script/Dockerfile` with `--target deps`
for the existing build sandbox and `--target runtime` for the
shippable image. The problem: the build sandbox uses
`docker build` context = `script/`, which contains nothing but
the Dockerfile. The runtime stage needs to COPY `lisp/`, `elp/`,
`mediaserver.asd` into the image, which requires context =
repo root + a `.dockerignore`. The two contexts are
incompatible in one Dockerfile. Cleaner to have:
- `script/Dockerfile` — current build sandbox, context `script/`,
  unchanged.
- `script/Dockerfile.runtime` — multi-stage runtime image,
  context = repo root, with a `.dockerignore` to keep it sane.

**Why static Dockerfile.runtime, not templated via ELP.** The
substitution surface is small and not loop-shaped. If we templated
it via ELP, we'd hit a bootstrapping circularity (`bin/render`
rendering its own Dockerfile). That circularity is solvable
(commit the rendered file, or ship a hand-written bootstrap
Dockerfile) but the payoff for *this* repo is mostly aesthetic.
Revisit if the dep lists grow loops or conditional branches; for
now, plain text.

**Base for the final stage: open question.** Two reasonable
options:
- `FROM scratch` + explicit COPY of every `.so` the binary needs
  (libc, libm, libzstd, libyaml, ld-linux). Most minimal,
  most explicit.
- `FROM gcr.io/distroless/base-debian12` — ships glibc + libssl
  + ca-certs out of the box. Need to add libzstd and libyaml.
  Slightly larger but less .so plumbing.

Default proposal: `FROM scratch`, copy each `.so` from the build
stage. It's more lines but it makes the dep set legible — anyone
reading the Dockerfile sees exactly which libraries the binary
needs. Revisit if the COPY lines start to feel ugly.

**Discovery: out of scope.** We know the binary needs
`libyaml-0.so.2` (verified via `LD_DEBUG=libs ./bin/render` in the
prior thread). Hard-code it. If a future code change adds a new
dlopened C lib, the runtime image will crash at first use of
that path; that's a documented contract, not a tool to build.

**Build-service-config too?** `bin/build-service-config` is a
build-time tool — it generates `services/manifest.yaml` from
the per-service yamls. It's not something a user of the runtime
image needs to invoke. Skip it from the runtime image. If
someone actually wants both binaries in one image later, easy
addition.

**Image needs bind-mount to be useful.** The image contains the
binary, not the source templates or the manifest. Real use is
`docker run -v $(pwd):/work -w /work mediaserver-render <args>`.
Document the invocation in a comment on the `make image` target;
no wrapper script needed for v1.

## Commits

1. **Add `.dockerignore` at repo root.** Excludes `config/`,
   `bin/`, `lib/`, `tmp/`, `worktrees/`, `.git/`, `test/config/`,
   anything else big and irrelevant. Keeps `docker build` context
   small (currently the repo would send GBs without this).
   *Verify:* `tar -czh -X <(grep -v '^#' .dockerignore) | wc -c`
   under ~1MB, or just `du -sh` the source files we expect to
   land in the build context (lisp/, elp/, services/, targets/,
   mediaserver.asd).

2. **Add `script/Dockerfile.runtime`.** Three stages:
   `deps` (FROM debian:bookworm-slim + apt + sbcl + quicklisp +
   dep prefetch — same content as current script/Dockerfile,
   factored out so the runtime build doesn't redo it), `build`
   (FROM deps, COPY `mediaserver.asd lisp/ elp/`, run sbcl
   `save-lisp-and-die` to produce `/build/render`), `runtime`
   (FROM scratch, COPY render + libyaml + needed glibc bits,
   ENTRYPOINT `["/render"]`). No make integration yet — just
   the Dockerfile.
   *Verify:* `docker build -f script/Dockerfile.runtime -t
   mediaserver-render:test .` succeeds. `docker run --rm
   mediaserver-render:test --help` produces the clingon help
   output (proves binary loaded, libyaml resolved). `docker
   image ls` shows size in expected ballpark.

3. **Add `make image` target wrapping the build.** One Makefile
   stanza. Maybe a `make image-shell` companion that runs an
   interactive shell in the runtime image with bind-mount, for
   debugging. Update CLAUDE.md or README with a one-line
   pointer. (Decision at exec time: which file gets the
   one-liner.)
   *Verify:* `make image` from a clean tree produces the image.
   `docker run --rm -v $(pwd):/work -w /work mediaserver-render
   --service prometheus services/prometheus/prometheus.yml.elp`
   produces output byte-identical to host-built `bin/render`
   against the same template (`diff <(host-bin) <(image-bin)`
   shows no diff).

4. **Smoke check the runtime image against an existing fixture.**
   Add a tiny verifier — render one fixture template through the
   image, diff against host-rendered. Either as a make target
   (`make image-check`) or a `script/check-runtime-image.sh`.
   Keep it small. This is the standing alarm that says "you
   added a dep that dlopens a new .so and forgot to add it" —
   the failure mode the plan accepts as a documented contract,
   but a smoke test makes it land in test rather than in prod.
   *Verify:* `make image-check` passes. Deliberately remove
   the `libyaml` COPY from the Dockerfile and rebuild — check
   fails loudly.

## Future plans

- **Extract `lispship` (or whatever it's called) as a separate
  project.** A reusable tool that takes `(base_image, c-deps,
  lisp-deps, entry-point, optional smoke-cmd)` and produces a
  minimal docker image. Worth doing only after this plan ships
  and we've used the pattern for a while. The interesting part
  is what we'd skip from this plan's design (the discovery step,
  the per-distro dep names) versus what generalises (the three-
  stage layout, the .dockerignore).
- **Smoke-based `.so` discovery.** Run the binary with
  `LD_DEBUG=libs <smoke-cmd>` during build, parse the output,
  COPY exactly those `.so`s into the runtime stage. Replaces
  the hard-coded libyaml. Becomes valuable when there are 3+
  C deps to track.
- **Multi-arch (amd64 + arm64).** If we ever want to run on a
  Pi or ARM cloud host. QEMU + buildx territory. Out of scope
  until there's a concrete target.

## Non-goals

- **No new tool, no extracted project.** This plan is one repo,
  one docker image. The "ko-for-CL" framing is a way of thinking
  about it, not a deliverable.
- **No automation around `.so` discovery.** Hard-coded libyaml.
- **No multi-distro support.** Debian bookworm only. The
  Dockerfile bakes in `libyaml-0-2`, `apt`, etc. — explicitly
  Debian-flavored, by design.
- **No changes to the existing build path.** `make all` /
  `script/build.sh` / `script/Dockerfile` keep doing exactly
  what they do today.
- **No ELP templating of the Dockerfile.** Static text only.
  Revisit only if the dep lists become loop-shaped.
