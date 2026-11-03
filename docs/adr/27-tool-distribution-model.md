# ADR-27 — Tool distribution and installation model

Status: **Accepted, 2026-05-22; partially implemented.**

Records how
Rigor is distributed to and installed by end users. The core
principle — **Rigor is not added to the target project's `Gemfile`**
— is ratified, as is the latest-Ruby-only stance it rests on (WD7).
The channel recommendations follow: a runtime-version manager
(`mise` / `asdf`) is the front-line path, a copy-pasteable standalone
CI workflow template is the CI path (Nix is an alternative, not the
headline), and a container image plus a self-contained single binary
are the secondary / future options. **Shipped so far:** the Nix flake
`packages` / `apps` outputs, a published container image (`Dockerfile`
+ `.github/workflows/container.yml`), and the machine-readable install
guide (`docs/install.md`, v0.1.14) de-recommending the `Gemfile`
entry, and the copy-pasteable standalone CI workflow templates — which
landed via [ADR-51](51-ci-diagnostic-output-formats.md) WD6
(`docs/manual/ci-templates/` + the bundled `rigor-ci-setup` skill).
**Still queued:** the self-contained single binary. **Amended
2026-11-04 (#2725, decided by the maintainer):** WD9 makes a
committed, Rigor-only pinned bundle at `.github/rigor/` a documented
channel below the version manager, and WD10 lets the VS Code extension
install that bundle's per-user form for first-time users (landing
with WD10); WD1 no longer rules the isolated bundle out.

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

5. **Secondary — a pinned bundle.** A committed Rigor-only `Gemfile`
   and lockfile at `.github/rigor/`, selected with `BUNDLE_GEMFILE`,
   for teams that run everything through Bundler; it does not
   provision Ruby (WD9). The VS Code extension installs a per-user
   form of it for a first-time user (WD10).

6. **Retained — global `gem install rigortype`.** Kept as a
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

No onboarding material recommends the project `Gemfile` entry. An
entry that already exists, on a project that itself runs Ruby 4.0, is
not a supported channel either: it is a state `rigor doctor` diagnoses
by its concrete harms (the Ruby ceiling, a divergent `rbs` lock, a
missing `require: false`;
[#2751](https://github.com/rigortype/rigor/issues/2751)).

A `Gemfile` holding nothing but Rigor, resolved separately — the
`ruby-lsp` "composed bundle" pattern — solves the *resolution*
contamination cleanly but **does not solve interpreter provisioning**:
the user still needs a Ruby 4.0. That is why the version manager (WD2)
stays front-line. The isolated bundle is a channel in its own right,
though, below it: WD9 records it, and WD10 its per-user form in the
editor.

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

### WD9 — A pinned bundle is the documented secondary channel

*Decided by the maintainer 2026-11-04
([#2725](https://github.com/rigortype/rigor/issues/2725)).* A committed
Rigor-only `Gemfile` and its lockfile at **one canonical path,
`.github/rigor/`**, selected with `BUNDLE_GEMFILE`
(`BUNDLE_GEMFILE=.github/rigor/Gemfile bundle exec rigor check`). The
path is the one the CI template (WD3, manual chapter 11) and the
`rigor-ci-setup` skill already use. WD3's CI-only `Gemfile` is meant to
be this WD applied to CI; its template does not yet carry the `ruby`
line or the current version constraint
([#2759](https://github.com/rigortype/rigor/issues/2759)).

It ranks below the version manager and above a bare `gem install`
(WD6). What it buys: isolation from the project's bundle (Rigor's
gems never meet the application's resolution), Dependabot updates, one
pin read by local runs and CI alike, and a home for third-party plugin
gems that a version manager's `gem:` backend may not load
([#2752](https://github.com/rigortype/rigor/issues/2752)).

**It does not provision Ruby.** Every invocation must already run a
Ruby 4.0, so the `Gemfile` carries `ruby ">= 4.0.0", "< 4.1"` and a
wrong Ruby fails at `bundle exec` rather than inside the analyzer.
Nor does it make the transitive gems reproducible in any verifying
sense: the lockfile is written by the same resolution that downloads
them. A lockfile produced at release time would change that
([#2754](https://github.com/rigortype/rigor/issues/2754)); until then
it is not claimed.

Follow-ups: the VS Code extension discovers `.github/rigor/`
([#2750](https://github.com/rigortype/rigor/issues/2750)), `rigor
doctor` recognises it (#2751), and the CI template's `bundler-cache`
must not install Rigor's gems where Rigor reads them as the project's
bundle ([#2753](https://github.com/rigortype/rigor/issues/2753)).

**Acceptance:** the installation guide and manual chapter 01 present
it under the version manager with the `ruby` range; doctor and the
extension recognise the path (#2750, #2751). **Revisit when:** the
single binary (WD5) ships, or #2754 lands a release lockfile (then
reproducibility can be claimed).

### WD10 — The editor installs a per-user pinned bundle for a first-time user

*Decided by the maintainer 2026-11-04 ([#2725](https://github.com/rigortype/rigor/issues/2725)).*
WD9's bundle, kept per user in the editor's storage rather than
committed to a project: a first-time user who installs the VS Code
extension gets diagnostics without first installing Rigor by hand.
It shares WD9's limit and does not pretend otherwise — it needs a
Ruby 4.0, or one the user lets mise install.

**Criterion: it serves a user who has no Rigor yet, and nobody who has
one.** It is the *last* discovery kind (`managed`, after explicit
path, Bundler, `PATH` and the mise / asdf shim in
`editors/vscode/src/discovery.ts`; an earlier kind that is found but
does not run falls through to it, one that runs but is too old does
not). A project that pins `rigortype` — in `Gemfile.lock` or
`.github/rigor/Gemfile.lock`, or in the `[tools]` of a mise / asdf
file at the project root or above it, short of the home directory —
is never served by it, even when that pin is not installed. The
user's global mise / asdf config counts only while a rigortype is
installed through it. Pins are read from the files: the extension
never runs `mise` to resolve one (a `mise` command can run the user's
configured auto-prune, which uninstalls tools — observed while
building this). Nothing is installed in an untrusted workspace or
without the user's click.

Tiers, by what the machine has (`editors/vscode/src/runtime.ts`):

- **A — a Ruby 4.0 exists** (`rigor.runtime.rubyPath`, `ruby` on
  `PATH`, the mise / rbenv / chruby / asdf install directories; each
  candidate checks `Gem.ruby_version` against the gemspec's
  `required_ruby_version`, which a gate keeps the extension's copy
  equal to; the first in that order with Bundler and OpenSSL wins, a
  prerelease, which `< 4.1` admits, only when `rigor.runtime.rubyPath`
  names it, and a build that fails the way a broken Ruby does is tried
  once more with the next).
  The extension writes a one-line `Gemfile`
  into its storage and runs `bundle install` with `BUNDLE_GEMFILE`,
  `BUNDLE_PATH` and `BUNDLE_IGNORE_CONFIG=1` set, dropping every
  inherited `BUNDLE_*` / `BUNDLER_*` variable (but
  `BUNDLE_MIRROR__*`), `GEM_HOME`, `GEM_PATH`, `RUBYOPT` and
  `RUBYLIB`. The server is `ruby <bundler> exec rigor lsp` with the
  project as its working directory.
- **B — no Ruby 4.0, but mise.** The extension offers to run `mise
  install ruby@4.0` — its one deliberate `mise` invocation, after a
  click, with a prompt that says mise applies the user's own settings
  (auto-prune among them) — then continues as A. Closing the window
  leaves that install running to completion, writing to a log file in
  the storage, rather than killing it half-built; while that log is
  recent no window starts another.
- **C — neither.** The extension shows the installation guide and
  points at WD5's single binary
  ([#926](https://github.com/rigortype/rigor/issues/926)); when that
  ships, C downloads it instead.

The storage is per user and every VS Code window shares it: an install
builds in a temporary directory under a heartbeat lock file and is
renamed into `runtime/<version>/`; each window marks the version its
servers run, and pruning (newest two kept) and repair skip a version
another live window marks (a repair also one another folder of the
same window runs, and checks before it builds). The lock's heartbeat
and the markers follow the wall clock and refresh within seconds of a
wake, since a timer does not advance while macOS sleeps; a window that
judges a lock stale in those seconds can still take it over, the one
residue.

Updates follow PHPantom's model: while a folder runs the managed Rigor
and `rigor.runtime.version` is `latest`, the extension checks
rubygems.org shortly after startup and at most once every
`rigor.runtime.updateCheckIntervalHours` across the machine's windows
(`rigor.runtime.autoUpdate`, on by default; the last check and the
declined versions live in the extension's global state). A newer
release installs beside the current one only on the user's click and
is used from the next restart; a pin, an untrusted workspace or an
unreachable rubygems.org changes nothing.

Rigor reads the analysed project as data from this foreign bundle as
from a global install: measured for #2725,
`Plugin::Isolation.require_with_target_bundle` under
`BUNDLE_GEMFILE=<managed>` with the project as the working directory
resolved Erubi from the project's `vendor/bundle`, and `rigor check`
read the project's `Gemfile.lock`. One difference: a Bundler-locked
process cannot `require` a gem that sits only in the user's default
`GEM_HOME`, so ADR-90's fallback then has only the project-local
bundle paths `BundleSigDiscovery` auto-detects.

**Intended direction:** the install logic moves into a non-interactive
`rigor runtime …` helper that other editors (Neovim, Helix) call too,
with the extension as one client. Not built yet: VS Code is the only
client so far.

Rejected: the container image as tier C (WD4 — its paths do not match
the editor's file URIs); `gem install --install-dir` with `GEM_HOME`
(the fallback had the isolation measurement failed; Bundler keeps the
user's and the project's Bundler config out by construction);
installing on activation without a click.

**Acceptance:** on a machine with Ruby 4.0 and no `rigor`, the install
yields a running server whose kind is `managed`; a pinned project is
never served by it; nothing installs untrusted or unclicked; tier C
never shows a bare spawn error. **Revisit when:** the `rigor runtime`
helper is built, #926 ships (tier C), or #2754 lands (the managed
install can then use the release lockfile).

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
- **A second code path in the editor (WD10).** The extension now
  installs and versions a Rigor of its own, beside discovery, until the
  shared `rigor runtime` helper takes that over.
- **Per-user state shared across windows (WD10).** Every VS Code
  window reads and writes the same storage, which is why it needs the
  lock, the atomic rename and the in-use markers.
- **The Ruby range is hard-coded in two places.** The pinned bundle's
  `ruby` line (WD9) and the extension's Ruby check (WD10) copy the
  gemspec's `required_ruby_version`
  ([#2755](https://github.com/rigortype/rigor/issues/2755)).
- **Transitive versions drift between installs (WD9, WD10).** Only
  `rigortype` is pinned until a release lockfile exists (#2754).

### Carry-over

- The single-binary channel (WD5) is unresolved — `tebako` viability
  on Ruby 4.0 versus a homegrown packaging is an open spike.
- The CI-template timing risk (WD3) — **resolved 2026-06-13.**
  `ruby/setup-ruby` ships prebuilt Ruby 4.0.x binaries for
  ubuntu-latest (verified via `ruby-builder-versions.json`: versions
  `4.0.0` through `4.0.5` are listed; setup-ruby resolves `"4.0"` to
  `4.0.5` and loads it from `/opt/hostedtoolcache/Ruby/4.0.5/x64/bin`
  in ~0.30 s, confirmed against Rigor's own CI run 27444146655 on
  2026-06-12). The Nix-with-cache bridge mentioned in WD3 is not
  needed; `ruby/setup-ruby` is the primary fast path.
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
