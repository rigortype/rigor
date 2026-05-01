# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1] - 2026-05-01

First preview release. Establishes the end-to-end pipeline from Ruby source
to diagnostics through a flow-sensitive type-inference engine, and ships a
small but usable CLI.

### Added

- `rigor check PATH...` runs the analysis pipeline over Ruby files and prints
  diagnostics. `--format=json` switches to machine-readable output.
- `rigor type-of FILE:LINE:COL` probes `Rigor::Scope#type_of` at a source
  position and prints the inferred type and its RBS erasure. `--trace`
  records fail-soft fallbacks via `Rigor::Inference::FallbackTracer`.
- `rigor type-scan PATH...` walks every Prism node, runs `Scope#type_of` on
  each, and reports per-node-class coverage plus fallback example sites.
  `--threshold=RATIO` makes it usable as a CI gate.
- `rigor init` writes a starter `.rigor.yml`; `--force` overwrites an
  existing file intentionally.
- `rigor help` and `rigor version` for CLI discovery.
- Inference engine recognises the bulk of canonical Ruby surface: literals,
  local variables, ivars / cvars / globals (intra- and cross-method),
  `self` typing, lexical constant lookup, control-flow joins,
  predicate narrowing (`is_a?` / `kind_of?` / `instance_of?` / `==` / `===`
  / `nil?` / `case`-`when`), block parameter binding, closure escape
  analysis, `Tuple` and `HashShape` carriers with shape-aware element
  dispatch, destructuring (multi-target / numbered params / `block_type:`),
  and RBS-backed method dispatch with overload selection and generics
  instantiation.
- Project-aware RBS environment: loads project signatures plus a default
  stdlib set (`pathname`, `optparse`, `json`, `yaml`, `fileutils`,
  `tempfile`, `uri`, `logger`, `date`, `prism`, `rbs`).
- Public RBS signatures for Rigor itself under `sig/`.
- Documentation set: `docs/types.md` quick guide, normative type
  specification under `docs/type-specification/`, analyzer-internal
  contracts under `docs/internal-spec/`, and ADRs under `docs/adr/`.

[Unreleased]: https://github.com/rigortype/rigor/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/rigortype/rigor/releases/tag/v0.0.1
