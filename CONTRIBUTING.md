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
- [`docs/MILESTONES.md`](docs/MILESTONES.md) — the
  release-by-release commitment envelope.
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

## License

By contributing to Rigor you agree that your contribution is
licensed under the [Mozilla Public License Version 2.0](LICENSE),
the same license the project ships under.
