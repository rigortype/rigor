# Contributing to Rigor

Thanks for taking a look at Rigor. This document covers the
**minimum** path from `git clone` to a green test run. The
[`AGENTS.md`](AGENTS.md) file is the authoritative agent /
contributor contract — read it once before sending a non-trivial
patch.

## Prerequisites

- **Recommended:** Nix with the `nix-command` and `flakes`
  experimental features enabled. The Flake provides Ruby 4.0,
  Bundler 4, GNU Make, Git, and the rest of the build
  toolchain at the exact versions CI uses.
- **Or, without Nix:** Ruby `>= 4.0.0, < 4.1` and a matching
  Bundler 4.x on `PATH`. CI runs through
  [`ruby/setup-ruby`](https://github.com/ruby/setup-ruby) and
  proves this path works; just be aware that you are then
  responsible for matching the versions yourself.

## Clone and set up

```sh
git clone https://github.com/rigortype/rigor.git
cd rigor

# With Nix (recommended). Single-command setup that installs
# gems, applies safe submodule defaults, and pulls the
# read-only references the engine ships against.
nix --extra-experimental-features 'nix-command flakes' develop --command make setup

# Without Nix. Equivalent commands run directly:
bundle install
make init-git-config
make init-submodules
```

If `nix` is not on `PATH`, substitute
`/nix/var/nix/profiles/default/bin/nix`.

`make init-submodules` clones the read-only specifications
under `references/` (RBS, ruby/ruby on the `ruby_4_0` branch,
PHPStan website, python/typing, etc.). The submodules are large;
`init-submodules` already passes `--filter=blob:none` so first-
clone bandwidth stays reasonable.

## Run the tests

```sh
# With Nix (recommended).
nix --extra-experimental-features 'nix-command flakes' develop --command make verify

# Or inside the Flake shell:
nix --extra-experimental-features 'nix-command flakes' develop
make verify

# Without Nix, the same target works directly:
make verify
```

`make verify` chains:

- `make test` — the RSpec suite.
- `make lint` — RuboCop.
- `make check` — `bundle exec exe/rigor check lib`, the
  project's own self-check.

A clean run reports `0 failures` from RSpec, `no offenses`
from RuboCop, and `No diagnostics` from the self-check. CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml))
runs the same target.

For a quicker loop while iterating:

```sh
make test                  # rspec only
make lint                  # rubocop only
make check                 # rigor self-check only
bundle exec rspec spec/rigor/type/refined_spec.rb  # one file
```

## Where to read next

- [`AGENTS.md`](AGENTS.md) — the binding development contract:
  Flake mandate, target Ruby, common commands, directory
  layout, references / submodule rules, commit-message style,
  verification protocol.
- [`CLAUDE.md`](CLAUDE.md) — agent-readable navigation index
  pointing at the spec / ADR documents that bind any change to
  the type model or analyzer-internal contracts.
- [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md) — transient
  resume bookmark for the next implementer (highest-leverage
  open slices, parallel-safe entry points, open engineering
  items).
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — the
  forward-looking commitment envelope (active cycle + queued
  work). The released-version record is `CHANGELOG.md`.
- [`docs/adr/`](docs/adr/) — architecture decision records.
- [`docs/type-specification/`](docs/type-specification/) — the
  normative type-language specification.
- [`docs/internal-spec/`](docs/internal-spec/) — analyzer-
  internal contracts (engine surface, type-object public
  API).

## Submitting changes

Rigor's contribution policy is organised by **change magnitude**
per [ADR-31](docs/adr/31-contribution-and-supply-chain-policy.md):
minor focused changes are welcomed as direct pull requests
against any path in the repo; sweeping changes go through an
issue-first proposal route. Plugin authorship has its own
companion paths (see "Plugin contributions" below).

### Direct pull requests are welcomed for minor changes

Send a PR for any **minor, focused** improvement — bug fixes,
documentation improvements, typo / broken-link fixes, test
additions, small refactors, tooling improvements, bug fixes to
existing bundled plugins. The heuristic is informal: "could a
careful reviewer audit this diff in one sitting and be confident
nothing harmful is hiding in it." If yes, send the PR.

When opening a PR:

- Keep the change small and aligned with the existing structure.
  The ADR / spec corpus binds: changes that touch type-model
  behaviour or analyzer-internal contracts MUST be reflected in
  the relevant `docs/type-specification/` or `docs/internal-spec/`
  document in the same patch.
- Run `make verify` before pushing.
- Use plain imperative subject lines in sentence case
  (`Add Type::Refined acceptance rule`, not
  `feat: add type::refined acceptance`). See [`AGENTS.md`](AGENTS.md)
  for the commit-message conventions.
- Open the pull request against `master`. CI must be green
  before review.

### Issue-first for sweeping changes

For larger changes — architectural rewrites, non-trivial engine
refactors, new analyser features, code-style sweeps / formatting
reflows, new bundled plugins, retractions of normative ADR / spec
decisions — please file a GitHub issue first describing the
proposal and the rational reasons behind it, rather than opening
the PR directly. If the team agrees with the direction, the team
implements; your contribution is recorded via
[`Co-authored-by:`](https://docs.github.com/en/pull-requests/committing-changes-to-your-project/creating-and-editing-commits/creating-a-commit-with-multiple-authors)
on the implementation commit(s) — please be assured that
attribution is preserved.

The asymmetry exists because merge-time code review can reliably
audit small focused diffs but not thousand-line refactors;
issue-first ensures both alignment (you don't invest in code the
team would have wanted to go a different way) and the supply-
chain hygiene that comes from the team owning the implementation
for changes too large to review post-hoc. See
[ADR-31 WD1](docs/adr/31-contribution-and-supply-chain-policy.md)
for the full rationale.

If you're unsure whether a change counts as minor or sweeping,
**file an issue first** — the team will tell you whether a PR
is fine or whether to iterate on the design before coding.

## Plugin contributions

New bundled plugins (`plugins/rigor-<gem>/`) follow their own
paths per
[ADR-31 WD2–WD5](docs/adr/31-contribution-and-supply-chain-policy.md):

- **Third-party plugin (default).** Author a `rigor-<gem>` gem
  in **your own repo**, depending on `gem "rigortype"`. This is
  a Larger Work under [MPL §3.3](LICENSE) — your own plugin
  files can be MIT, BSD, Apache 2.0, MPL-2.0, or any other
  licence permitted by the wrapped gem; the rigor code you
  redistribute stays MPL. Fully supported, no upstream
  involvement required. See
  [ADR-31 WD4](docs/adr/31-contribution-and-supply-chain-policy.md)
  and the
  [`rigor-plugin-author`](.claude/skills/rigor-plugin-author/SKILL.md)
  SKILL (Phase 0.5 routes non-maintainers to this path).
- **Propose for official bundling via issue.** When a third-party
  plugin reaches significant community adoption, file a GitHub
  issue with the wrapped gem's identity, evidence of adoption,
  and a pointer to your working third-party plugin as reference
  material. The Rigor team re-implements in `plugins/` from
  scratch and credits you via `Co-authored-by:` on the
  implementation commit(s). See
  [ADR-31 WD2 / WD3](docs/adr/31-contribution-and-supply-chain-policy.md).
- **FFI plugins specifically.** Start with the
  [`rigor-ffi-plugin-author`](.claude/skills/rigor-ffi-plugin-author/SKILL.md)
  SKILL's coverage assessment — for the typical "literal
  `attach_function` + thin Ruby wrapper" gem, the bundled core
  `rigor-ffi` plugin suffices and no per-gem plugin is needed at
  all. The SKILL is designed to talk you out of authoring a
  plugin when core covers your case. See
  [ADR-30 WD10](docs/adr/30-rigor-ffi-plugin-shape.md).

Bug fixes to **existing** bundled plugins
(`plugins/rigor-rails-routes/`, `plugins/rigor-activerecord/`,
etc.) are minor PRs and follow the "Direct pull requests" path
above — they don't go through the WD2 route, which is for
**new** bundled plugins.

Subtree merge of a proven third-party plugin into the monorepo
is reserved as a rare optional path subject to four conjunctive
conditions ([ADR-31 WD5](docs/adr/31-contribution-and-supply-chain-policy.md));
it is not a path third-party authors should plan around.

## License

Rigor is licensed under the
[Mozilla Public License Version 2.0](LICENSE).

- **All pull request contributions** are licensed under MPL-2.0
  on merge; the contributor becomes an MPL §1.1 Contributor on
  the files they touch and makes the §2.5 representation by
  submitting the PR (Contributions are the contributor's
  original creation or they have sufficient rights to grant the
  conveyed licence).
- **Issue-driven proposals** (sweeping changes implemented by
  the Rigor team) make the Rigor team member who authors the
  code the MPL §1.1 Contributor of record; the proposer's
  `Co-authored-by:` trailer is informational attribution rather
  than transfer of Contributor status.
- **Third-party plugins** (separate `rigor-<gem>` gems in their
  own repos per "Plugin contributions" above) are Larger Work
  under §3.3; their authors are free to license their own files
  under the licence of their choice, subject to compliance with
  the MPL for the rigor code they redistribute.
