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

- Keep the change small and aligned with the existing
  structure. The ADR / spec corpus binds: changes that touch
  type-model behaviour or analyzer-internal contracts MUST be
  reflected in the relevant `docs/type-specification/` or
  `docs/internal-spec/` document in the same patch.
- Run `make verify` before pushing.
- Use plain imperative subject lines in sentence case
  (`Add Type::Refined acceptance rule`, not
  `feat: add type::refined acceptance`). See
  [`AGENTS.md`](AGENTS.md) for the commit-message conventions.
- Open a pull request against `master`. CI must be green
  before review.

## Plugin contributions

Plugins follow a separate contribution policy from core changes:
**Rigor does not accept external pull requests into `plugins/`
or `examples/`**. The supply-chain rationale and the welcoming
alternative routes are recorded in
[`docs/adr/31-plugin-contribution-policy.md`](docs/adr/31-plugin-contribution-policy.md);
the short summary:

- **Third-party plugin (default).** Author a `rigor-<gem>` gem
  in **your own repo**, depending on `gem "rigortype"`. This is
  a Larger Work under [MPL §3.3](LICENSE) — your own plugin
  files can be MIT, BSD, Apache 2.0, MPL-2.0, or any other
  licence permitted by the wrapped gem; the rigor code you
  redistribute stays MPL. Fully supported, no upstream
  involvement required. See
  [ADR-31 WD4](docs/adr/31-plugin-contribution-policy.md)
  and the
  [`rigor-plugin-author`](.claude/skills/rigor-plugin-author/SKILL.md)
  SKILL (Phase 0.5 routes non-maintainers to this path).
- **Propose for official bundling via issue.** When a third-party
  plugin reaches significant community adoption, file a GitHub
  issue with the wrapped gem's identity, evidence of adoption,
  and a pointer to your working third-party plugin as reference
  material. If accepted, the Rigor team re-implements the plugin
  in `plugins/` from scratch and credits you via
  [`Co-authored-by:`](https://docs.github.com/en/pull-requests/committing-changes-to-your-project/creating-and-editing-commits/creating-a-commit-with-multiple-authors)
  on the implementation commit(s). See
  [ADR-31 WD2 / WD3](docs/adr/31-plugin-contribution-policy.md).
- **FFI plugins specifically.** Start with the
  [`rigor-ffi-plugin-author`](.claude/skills/rigor-ffi-plugin-author/SKILL.md)
  SKILL's coverage assessment — for the typical "literal
  `attach_function` + thin Ruby wrapper" gem, the bundled core
  `rigor-ffi` plugin suffices and no per-gem plugin is needed at
  all. The SKILL is designed to talk you out of authoring a
  plugin when core covers your case. See
  [ADR-30 WD10](docs/adr/30-rigor-ffi-plugin-shape.md).

Subtree merge of a proven third-party plugin into the monorepo
is reserved as a rare optional path subject to four conjunctive
conditions ([ADR-31 WD5](docs/adr/31-plugin-contribution-policy.md));
it is not a path third-party authors should plan around.

## License

Rigor is licensed under the
[Mozilla Public License Version 2.0](LICENSE).

- **Core code contributions** (commits the Rigor team authors
  and merges into this repository) are licensed under the MPL-2.0
  the same as the rest of the project; the author becomes an MPL
  §1.1 Contributor and makes the §2.5 representation that the
  Contribution is their original creation or that they have
  sufficient rights to grant the conveyed licence.
- **Third-party plugins** (separate `rigor-<gem>` gems in their
  own repos per the previous section) are Larger Work under
  §3.3; their authors are free to license their own files under
  the licence of their choice, subject to compliance with the
  MPL for the rigor code they redistribute.
