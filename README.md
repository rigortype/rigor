# Rigor

Rigor is a static analyzer for Ruby that aims to provide modern, inference-first type checking without adding type annotations or runtime dependencies to application code.

The current repository is an early scaffold for the CLI-first MVP described in [ADR-0](docs/adr/0-concept.md). The first implemented analysis surface is intentionally small: parse Ruby source with Prism, report syntax diagnostics, and provide stable project boundaries for the future control-flow and type-inference engine.

## Requirements

- Nix with the `nix-command` and `flakes` features available
- Ruby 4.0.3 and Bundler 4.x, provided by the Flake development shell

## Setup

Run development commands through the Flake so Ruby, Bundler, and gem tooling come from the project environment.

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle install
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rake
```

For interactive development, enter the Flake shell first:

```sh
nix --extra-experimental-features 'nix-command flakes' develop
```

## CLI

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor help
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor version
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor check lib
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor check --format=json lib
```

`rigor init` writes a starter `.rigor.yml` configuration file.

## Project Layout

- `lib/rigor`: runtime library and CLI implementation
- `lib/rigor/analysis`: analyzer result and diagnostic primitives
- `sig`: initial public RBS signatures for Rigor itself
- `spec`: RSpec test suite
- `docs/adr`: architecture decisions

## MVP Direction

The next implementation layer should build a control-flow graph on top of Prism ASTs, then introduce a type lattice capable of tracking literals, unions, nilability, and receiver method availability. The first user-facing type diagnostic should be the ADR-0 example: detecting a possible `NoMethodError` when a union receiver does not fully respond to a call.

## License

Rigor is licensed under the Mozilla Public License Version 2.0. See [LICENSE](LICENSE).
