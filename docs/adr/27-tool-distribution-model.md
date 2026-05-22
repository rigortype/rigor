# ADR-27 — Tool distribution and installation model

Status: **proposed, 2026-05-22.** Records how Rigor is distributed
to and installed by end users. The core principle — **Rigor is not
added to the target project's `Gemfile`** — is ratified, as is the
latest-Ruby-only stance it rests on (WD7). The channel
recommendations follow: a runtime-version manager (`mise` / `asdf`)
is the front-line path, a copy-pasteable standalone CI workflow
template is the CI path (Nix is an alternative, not the headline),
and a container image plus a self-contained single binary are the
secondary / future options. Implementation is queued; no slice is
scheduled by this ADR.

## Context

Rigor ships as the `rigortype` gem with an executable named `rigor`
(the gem is `rigortype` because `rigor` was taken on RubyGems). The
README's "Installation" section today recommends adding
`gem "rigortype"` to the target project's `Gemfile` under
`group :development`, with `gem install rigortype` as a one-off
alternative.

Two properties of the gem make the `Gemfile` path actively harmful:

1. **`required_ruby_version = [">= 4.0.0", "< 4.1"]`.** Rigor's own
   codebase targets Ruby 4.0 — the development Ruby pinned by
   `flake.nix` / `.ruby-version` (see `AGENTS.md`). Almost no
   production Ruby application currently runs on Ruby 4.0. A `Gemfile`
   entry carrying this constraint forces the *entire analyzed
   project* onto Ruby 4.0 — a non-starter for the audience Rigor is
   meant to serve.

2. **Three runtime dependencies** (`prism`, `rbs`,
   `language_server-protocol`). Even with the Ruby pin set aside,
   resolving these against the target project's own constraints
   reproduces the well-known pain of putting Steep or a heavy linter
   in an application `Gemfile` — version conflicts on shared gems
   (`rbs` in particular), and pollution of the dependency graph of an
   application that does not need Rigor at runtime.

Rigor is a **tool**, not a library. Like a compiler or a linter it
analyzes a project but is not part of that project's runtime. The
correct mental model is "a tool that runs with its own Ruby, pointed
at the project," not "a development dependency of the project." Rigor
reads the target project as *data* — it parses `Gemfile.lock`, walks
`vendor/bundle` `sig/` directories, reads `rbs_collection.lock.yaml`
(ADR-25) — it never loads the project's gems into its own Ruby
process. Nothing about analysis requires Rigor to share the project's
bundle, so nothing is lost by installing it separately.

The Ruby ecosystem already has prior art for this exact situation.
`solargraph` is conventionally kept out of the application `Gemfile`;
`ruby-lsp` (Shopify) explicitly recommends against a `Gemfile` entry
and instead bootstraps a separate "composed bundle" so the language
server's dependency tree is decoupled from the project's. Rigor faces
the same constraint, only sharper because of the hard Ruby 4.0 pin.

**Rigor deliberately targets only the latest Ruby**, and this ADR
records that as a decision, not an assumption (WD7). The Ruby 4.0 pin
is not an accident to be widened away: `ruby/rbs` — which Rigor is
built on — tracks the latest Ruby, and Rigor relies on Ractor and
other recent-runtime features (ADR-15). Supporting Ruby 3.3 / 3.4 is
a considered-and-rejected alternative. The distribution model below
is the *consequence* of that decision: because Rigor commits to a
Ruby that most analyzed projects do not run, it must be distributed
with its own Ruby. A tool should not dictate its host project's
runtime.

## Decision

**Rigor is not installed into the target project's `Gemfile`.** The
README and all onboarding material stop recommending the
`group :development` entry. Every recommended channel installs Rigor
*isolated from the target project's bundle*, so Rigor's Ruby and its
three dependencies never enter the analyzed project's resolution.

The recommended channels, in priority order:

1. **Front-line — a runtime-version manager (`mise`, `asdf`).** The
   headline recommendation. A version manager provisions *both*
   Ruby 4.0 *and* a pinned `rigortype` version, per project, with no
   `Gemfile` contamination (WD2).

2. **CI — a standalone workflow template.** A copy-pasteable
   `.github/workflows/rigor.yml` that runs Rigor in its own isolated
   job (`ruby/setup-ruby` for Ruby 4.0, install, `rigor check`). Nix
   is offered as an alternative hermetic CI path (WD3).

3. **Secondary — container image.** A published OCI image with
   Ruby 4.0 baked in, for CI and zero-Ruby environments where Nix is
   not wanted (WD4).

4. **Future — a self-contained single binary.** A single executable
   bundling Ruby plus the gem, so distribution becomes "download one
   file." `tebako` is the obvious tool; a lighter homegrown packaging
   is worth a spike. Uncommitted (WD5).

5. **Retained — global `gem install rigortype`.** Kept as a
   documented simple path for users who already have a Ruby 4.0 on
   `PATH`, but no longer the headline (WD6).

Nix (a `packages` / `apps` flake output) is retained as an
alternative for users and CI that already run Nix and want a
hermetic closure; it is not a headline channel (WD3).

## Working decisions

### WD1 — Rigor is not a project `Gemfile` dependency

The `group :development` `gem "rigortype"` recommendation is removed
from the README and from every onboarding SKILL. The reasons are in
§ Context: the Ruby 4.0 pin contaminates the host project's runtime,
and the three runtime dependencies contaminate its resolution. This
is the decision the rest of the ADR is built on.

The standalone-but-still-`Gemfile`-based alternative — Rigor
bootstrapping its own isolated bundle (`.rigor/Gemfile`, the
`ruby-lsp` "composed bundle" pattern) — was considered. It solves the
*resolution* contamination cleanly but **does not solve interpreter
provisioning**: the user still needs a Ruby 4.0 available. A version
manager (WD2) solves both at once, so the isolated-bundle bootstrap is
not pursued as a separate mechanism. The pattern remains a valid
fallback for a user who insists on a `bundle exec rigor` invocation
shape, and may be documented as such, but it is not a recommended
channel.

### WD2 — A runtime-version manager is the front-line channel

`mise` (and `asdf`, the same model) is the headline recommendation
because it is the only channel that, with one tool the user already
has for Ruby projects, solves *both* halves of the problem:

- **Interpreter provisioning** — `mise` installs Ruby 4.0 itself, so
  "the user must already have Ruby 4.0" stops being a precondition.
- **Per-project version pinning** — `mise.toml` / `.tool-versions`
  pins the `rigortype` version next to the Ruby version, committed to
  the repo, reproducible between local and CI, with zero `Gemfile`
  involvement.

`mise` is on a clear trajectory toward being the community-standard
runtime/tool manager for Ruby projects, which makes it both the most
ergonomic and the most future-aligned front-line channel. `asdf`
shares the model and is documented as the equivalent for users on it.

The gem itself is installed into the version-manager-managed Ruby
(the `gem` backend); the executable `rigor` is then on `PATH` inside
that environment. An on-`PATH` `rigor` is also the editor-friendliest
shape — editors launch `rigor lsp` over stdio (ADR-19), and a plain
`PATH` lookup is the simplest thing for every editor integration to
rely on.

### WD3 — CI is a standalone workflow template, run in an isolated job

The CI channel is a **copy-pasteable standalone workflow template**
(`.github/workflows/rigor.yml`), not a `setup-rigor` GitHub Action.

**Job isolation is mandatory.** Rigor runs in its own job — its own
runner, a fresh environment. This is not a stylistic preference; it
is the fix for a real conflict. `ruby/setup-ruby` sets the *job's*
active Ruby, so a job that provisions the project's test Ruby (often
a 3.2 / 3.3 / 3.4 matrix) cannot also provision Rigor's Ruby 4.0 —
the second `setup-ruby` call clobbers the first. A separate job —
better still a separate workflow file, for independent triggers,
concurrency, and a status badge — gives Rigor a clean environment
where `ruby/setup-ruby` for 4.0 conflicts with nothing. Splitting the
analyzer out of the test workflow is good practice regardless.

**A template, not an action.** Inside an isolated job the workflow is
~8 transparent lines: `actions/checkout`, `ruby/setup-ruby`
(`ruby-version: "4.0"`), install Rigor, `rigor check`. A composite
`setup-rigor` action wrapping those lines would add a maintained
artefact — marketplace presence, action versioning, a release
process — for thin value; its only real advantage is hiding the
`4.0` detail so a user cannot mis-edit it to match their project's
Ruby. A template is transparent, needs no third-party-action review,
and works on paste. The `setup-rigor` action is therefore **deferred
to demand**, not a v1 deliverable; the single binary (WD5), if it
lands, may change its value calculus.

**Version pinning and updates.** Dependabot does not see a
`gem install rigortype -v X` invocation inside a `run:` step — it
tracks `Gemfile` / gemspec (the `bundler` ecosystem) and `uses:`
action refs (the `github-actions` ecosystem), not arbitrary shell.
The template therefore offers two pinning forms:

- **Default — a CI-only isolated `Gemfile`.** A two-line
  `.github/rigor/Gemfile` (`gem "rigortype", "~> 0.1"`) plus its
  committed lockfile, consumed only by the Rigor job via
  `BUNDLE_GEMFILE`. A Dependabot `bundler` entry scoped to
  `directory: /.github/rigor` then auto-PRs Rigor updates, and the
  lockfile pins the three transitive dependencies for full
  reproducibility. This is the isolated-bundle pattern WD1 records as
  a valid fallback — here CI-scoped and non-root, so it never enters
  the application's resolution or constrains its Ruby.
  `ruby/setup-ruby`'s `bundler-cache: true` caches it.
- **Minimal — a pinned `gem install`.** `gem install rigortype -v
  "X.Y.Z"` for users who will not commit two files; fully visible,
  but updates are manual (Dependabot-invisible).

Nix is retained as a **documented alternative** CI path for teams
that already run Nix in CI and want a hermetic closure; it consumes
the flake `packages` / `apps` output (slice 2). Building the CI
channel *on* Nix plus a Cachix binary cache — modelled on
[`nix-emacs-ci`](https://github.com/purcell/nix-emacs-ci) — was
considered and rejected as the primary mechanism: `nix-emacs-ci`
builds its own prebuilt-binary layer (the cache) because CI has no
prebuilt Emacs, but Ruby already has that layer in `ruby/setup-ruby`,
so the Nix route is heavier machinery than the problem warrants.

One caveat to verify before shipping (slice 3): the template's speed
depends on `ruby/setup-ruby` publishing a *prebuilt* Ruby 4.0 for the
runner images. If a prebuilt 4.0 is not yet available, `setup-ruby`
compiles from source — minutes per run — until it is. A transient
timing risk (Ruby 4.0 is recent), not a structural one; the
Nix-with-cache alternative bridges it for teams that need fast CI in
that window.

### WD4 — Container image is the secondary CI / zero-Ruby channel

A published OCI image (`rigor check` as the entrypoint, the project
bind-mounted) is offered for CI and zero-Ruby environments that do
not want Nix. Ruby 4.0 is baked into the image; the host needs only a
container runtime.

It is *secondary*, not front-line, because the local-development and
editor-integration ergonomics are poor: bind-mount UID/permission
friction, a slow feedback loop, and `rigor lsp`-over-stdio through a
container is awkward for editors. The image is a CI / batch
convenience, not a development environment.

### WD5 — A self-contained single binary is the future ideal

The long-term ideal is a single self-contained executable bundling
Ruby plus the gem — distribution collapses to "download one file and
run it," the model Go and Rust tools enjoy, and the friction of every
other channel disappears.

`tebako` is the obvious existing tool. Its Ruby 4.0 support and build
complexity are unverified, and a single-binary release implies a
per-platform build matrix (the flake already targets four
`{aarch64,x86_64}-{darwin,linux}` systems). A *lighter homegrown*
packaging is explicitly worth a spike before committing to `tebako` —
e.g. a relocatable Ruby plus the gem shipped as a tarball with a
launcher script, or an AppImage / squashfs-style bundle. This is a
genuine engineering project, not a packaging tweak; it is **queued,
uncommitted**, with no milestone.

### WD6 — Global `gem install` is retained but de-emphasised

`gem install rigortype` stays documented as the simplest path for a
user who already has a Ruby 4.0 on `PATH`. It is honest and useful
for that audience, but it is no longer the headline: it provides no
per-project version pinning (local/CI drift) and still presupposes a
Ruby 4.0 the user mostly will not have. It sits below the
version-manager channel in all onboarding material.

### WD7 — Rigor stays latest-Ruby-only; 3.3 / 3.4 support is rejected

Rigor's `required_ruby_version` stays `>= 4.0, < 4.1`. Lowering the
floor to cover Ruby 3.3 / 3.4 — the versions most analyzed projects
actually run — is a considered-and-rejected alternative:

- **`ruby/rbs` tracks the latest Ruby.** Rigor is built on `rbs`;
  following `rbs` means following the Ruby it targets.
- **Ractor and other recent-runtime features.** Rigor's concurrency
  direction (ADR-15) and engine work rely on the latest runtime.
  A wider floor would forfeit those or force compatibility shims
  across the engine.
- The cost of a wider floor is paid on *every* contribution (avoiding
  newer syntax / APIs) and constrains the engine; the benefit —
  letting users run Rigor against their project's Ruby — is delivered
  instead by this ADR's distribution model, which lets Rigor run on
  its own Ruby regardless of the project's.

This decision is the premise the rest of the ADR rests on (see
§ Context). It may be revisited if the `rbs` or runtime-feature
calculus changes; it is not revisited by widening the pin
opportunistically.

### WD8 — Install on the host OS, not inside the dev container

A developer who works inside a development container (VS Code
devcontainers, a Docker-based dev environment) *can* install Rigor
inside that container, but the recommended placement on **non-Windows
hosts is the host OS**, alongside the version manager (WD2). Running
the analyzer inside the container adds inspection-overhead /
throughput cost across the filesystem and process boundary between
the analyzer and the host editor / files. On **Windows**, where a
reliable host-OS Ruby 4.0 is the weaker option, installing Rigor
inside the container is the recommended path.

This is independent of WD4: WD4 is Rigor's *own* published image as a
CI channel; WD8 is about where a developer places Rigor when they
themselves develop inside a container.

## Consequences

### Positive

- **Rigor stops dictating the host project's Ruby version.** The
  Ruby 4.0 pin becomes Rigor's private concern, not a constraint
  imposed on every analyzed project.
- **No dependency-graph contamination.** `prism` / `rbs` /
  `language_server-protocol` never enter the target project's
  resolution; no Steep-in-`Gemfile`-class conflicts.
- **Per-project reproducibility without `Gemfile` involvement.** The
  version-manager channel pins Ruby 4.0 and the `rigortype` version
  in `mise.toml` / `.tool-versions`, committed and reproducible.
- **CI is a transparent, copy-paste workflow.** A standalone
  `.github/workflows/rigor.yml` running Rigor in its own job is
  legible to any Ruby CI maintainer — no third-party action, no Nix
  or Cachix to adopt or operate.
- **Editor integration is simple.** Every recommended channel leaves
  `rigor` on `PATH`, which is all an editor needs to launch
  `rigor lsp` (ADR-19).

### Negative

- **More channels to document and maintain.** The README and SKILLs
  must explain a channel matrix instead of one `Gemfile` line. The
  Nix alternative still adds a `gemset.nix` / `buildRubyGem`
  maintenance burden (no binary cache is required now that Nix is an
  alternative, not the CI headline).
- **The familiar Ruby on-ramp is removed.** "Add it to your
  `Gemfile`" is what Ruby developers expect; WD1 deliberately breaks
  that expectation. The onboarding docs must explain *why* up front
  so it does not read as an omission.
- **No single recommended channel.** Local development, CI, and
  zero-Ruby environments are pointed at different channels. Mitigated
  by a clear priority order and a decision table in the docs.

### Carry-over

- The single-binary channel (WD5) is unresolved — `tebako` viability
  on Ruby 4.0 versus a homegrown packaging is an open spike.
- The CI-template timing risk (WD3) — whether `ruby/setup-ruby`
  publishes a prebuilt Ruby 4.0 — must be verified at slice 3.
- A `setup-rigor` composite action is deferred (WD3); revisit on
  demand, or if the single binary (WD5) changes its value calculus.

## Implementation slicing (proposed)

No slice is scheduled by this ADR.

### Slice 1 — documentation: de-recommend the `Gemfile` entry

- Rewrite the README "Installation" section: lead with the
  version-manager channel, present the channel matrix / decision
  table, demote `gem install`, drop the `group :development`
  recommendation.
- A dedicated `docs/installation.md` is a candidate home for the full
  matrix; `docs/manual/09-editor-integration.md` cross-references it.
- Update the `rigor-project-init` SKILL so its first step is a
  channel choice, not a `Gemfile` edit.

### Slice 2 — flake `packages` / `apps` output

- Add `packages.default` (Rigor as a derivation, Ruby 4.0 in the
  closure) and `apps.rigor` to `flake.nix`.
- `nix run github:rigortype/rigor -- check` and
  `nix profile install` both work.

### Slice 3 — the CI workflow template

- Author a standalone `.github/workflows/rigor.yml` template — Rigor
  in its own isolated job: `actions/checkout`, `ruby/setup-ruby`
  (Ruby 4.0), install Rigor, `rigor check`.
- Ship both pinning forms: the CI-only `.github/rigor/Gemfile` plus a
  matching Dependabot config snippet (default), and a pinned
  `gem install` (minimal variant).
- Verify `ruby/setup-ruby` publishes a prebuilt Ruby 4.0; if not yet,
  document the transient slow-build window and the Nix alternative.
- Document the Nix alternative CI path (consumes the slice-2 flake
  output) for teams that want a hermetic closure.

### Slice 4 — container image

- Add a `Dockerfile` and publish an image with `rigor` as the
  entrypoint and Ruby 4.0 baked in.

### Slice 5 — single-binary spike (uncommitted)

- Evaluate `tebako` on Ruby 4.0 against a lighter homegrown
  packaging; decide before committing to a build matrix.

## References

- [ADR-0](0-concept.md) — the zero-runtime-dependency, pure-Ruby,
  CLI-first stance this distribution model serves.
- [ADR-19](19-language-server-packaging.md) — the Language Server is
  bundled in the `rigortype` gem as `rigor lsp`; an on-`PATH` `rigor`
  is what editor integrations launch.
- [ADR-25](25-plugin-contributed-rbs.md) — how Rigor reads the target
  project's gem RBS as data, which is why isolated installation loses
  nothing.
- `rigortype.gemspec` — `required_ruby_version = [">= 4.0.0", "< 4.1"]`,
  the constraint that makes the `Gemfile` channel untenable.
- `flake.nix` — the existing `devShells`-only flake that slice 2
  extends with `packages` / `apps`.
- `README.md` § "Installation" — the current `Gemfile`-first text
  slice 1 rewrites.
- [`nix-emacs-ci`](https://github.com/purcell/nix-emacs-ci) — a Nix
  tool distribution aimed at CI; examined in WD3 and *not* followed
  as the primary CI route, because its binary-cache layer is one Ruby
  already has via `ruby/setup-ruby`.
- [`ruby/setup-ruby`](https://github.com/ruby/setup-ruby) — the
  prebuilt-Ruby CI provisioning the workflow template builds on.
- [Ruby branch / maintenance status](https://www.ruby-lang.org/en/downloads/branches/)
  — the support-window context behind WD7's latest-Ruby-only stance.
- Prior art for keeping a Ruby dev tool out of the application
  `Gemfile`: `solargraph` (conventional) and `ruby-lsp`'s "composed
  bundle" (explicit).
