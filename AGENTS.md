# AGENTS.md

This file is a development note for agents working in this repository. For the broader project context, read `README.md` and `docs/adr/0-concept.md`.

All project-authored documentation in this repository should be written in English. Treat external vendored or submodule documentation as upstream material and do not rewrite it only for language consistency.

## Project Overview

Rigor is an inference-first static analyzer for Ruby. It keeps application code free of type annotations and runtime dependencies, and starts with a CLI-first development experience.

The current implementation is an initial scaffold. It uses `Prism` to parse Ruby source files and exposes syntax diagnostics through the CLI as the smallest useful analysis surface.

## Development Environment

- Target Ruby is `4.0.3`.
- The gemspec requires Ruby `>= 4.0.0`, `< 4.1`.
- All development-time commands must run through the Flake. Do not run `bundle`, `rake`, `rspec`, `rubocop`, or `exe/rigor` directly from the host shell.
- The license is MPL-2.0.
- The official repository is `https://github.com/rigortype/rigor`.

Basic setup:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle install
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rake
```

For interactive work, enter the Flake shell first and then run development commands from inside that shell:

```sh
nix --extra-experimental-features 'nix-command flakes' develop
```

`flake.nix` points Bundler at `vendor/bundle`. Keep local gem installs isolated from global machine state whenever possible.

## Common Commands

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rake
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rspec
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rubocop
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor help
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor version
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor check lib
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor check --format=json lib
```

`rigor init` writes a starter `.rigor.yml` file. Use `--force` when overwriting an existing file intentionally.

## Directory Layout

- `lib/rigor`: library code and CLI implementation
- `lib/rigor/analysis`: diagnostics, analysis results, and the analysis runner
- `sig`: public RBS signatures for Rigor itself
- `spec`: RSpec test suite
- `docs/adr`: architecture decision records
- `docs/rbs`: upstream RBS submodule for specification and implementation reference

## Purpose of the docs/rbs Submodule

`docs/rbs` is a Git submodule that points to `https://github.com/ruby/rbs.git`. It exists as reference material so Rigor can stay compatible with the RBS ecosystem. Use it to inspect RBS syntax, standard library signatures, test cases, and implementation behavior.

This submodule is not Rigor runtime code. In normal implementation work, do not require/import files from `docs/rbs`, and do not copy upstream implementation into Rigor product code. Read the relevant specification or behavior there, then implement the smallest appropriate Rigor-side behavior.

If the submodule is empty after cloning:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command git submodule update --init --recursive docs/rbs
```

Update the submodule only when intentionally changing the referenced RBS version. During ordinary Rigor work, treat `docs/rbs` as read-only reference material.

## Implementation Guidelines

- Keep additions small and aligned with the existing structure and naming.
- Prioritize the CLI-first workflow. Do not assume an LSP server or long-running daemon yet.
- Preserve the design goal that Ruby application code should not require Rigor-specific annotations or DSLs.
- Use RBS for external dependency and standard library type information. Future Rigor-specific advanced type expressions should live in RBS comment extensions.
- Keep metaprogramming support out of the core where possible; steer it toward the future plugin API.

## Verification Notes

After making changes, run at least:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec rake
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

If the Flake shell or its dependencies are unavailable in the current environment, mention any skipped verification in the final report. For a minimal syntax-only check, run:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command sh -c 'for f in $(find bin exe lib spec -name "*.rb"); do ruby -c "$f" || exit 1; done'
```
