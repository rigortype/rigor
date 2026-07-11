# L1 fidelity review — coverage / CLI (2026-07-11)

Lens: L1 semantic fidelity, area A (coverage / CLI). Scope: `docs/manual/02-cli-reference.md`
(coverage + check), `15-type-protection-coverage.md`, `17-driving-improvement.md`,
`03-configuration.md`, `12-caching.md`. Verified against `--help`, scratch-dir probes, and
`lib/rigor/cli/{coverage_command,protection_report,mutation_protection_report,fused_protection_report}.rb`,
`lib/rigor/inference/dynamic_origin.rb`, `lib/rigor/environment/missing_gem_constant_index.rb`.

## Findings

| location | problem | severity | proposed fix |
| --- | --- | --- | --- |
| `02-cli-reference.md:266-363` (`## rigor coverage`, self-described "flag reference", 270-271) | The section documents every coverage flag (`--format`, `--config`, `--threshold`, `--protection`, `--mutation`, `--with-tests`, `--test-command`, `--include-dynamic`, `--limit`, `--seed`) **except `--workers=N`**, which PR #67 added to `coverage`. `coverage --help` lists it; `coverage_command.rb:101` defines it. A reader treating this as the complete reference misses that Tier-1 protection is now fork-parallelizable. | MISLEADING | Add `--workers=N` to the coverage flag reference, mirroring the `check` row (`02:44`): "Fork `N` workers over the scanned files (`--protection` only). Precedence `--workers` › `RIGOR_RACTOR_WORKERS` › `parallel.workers:` › `0` sequential." |
| `02-cli-reference.md:278-280` (`rigor coverage [paths]`) | Unlike the `check` section (`02:28-29`, "when omitted, Rigor checks the `paths:` list from the configuration file"), the coverage section never states that an omitted path now falls back to config `paths:` (default `lib`). PR #67 made this behaviour identical to `check` (`coverage_command.rb:80-83`); verified in a scratch dir (`rigor coverage` with no arg scanned `lib/`). Behaviour is undocumented, not misdocumented — no chapter still asserts the old "path required" error. | FRICTION | Add one line after the usage block: "When no path is given, Rigor uses the configured `paths:` (default `lib`), the same as `rigor check`." |
| `15-type-protection-coverage.md:30-52` (Tier 1) and `220-230` ("Cost and scope") | Post-PR #67, `--workers` is the Tier-1 speed lever, but the chapter never mentions coverage parallelism. Tier 1 is framed as "one analysis pass, fast enough to run interactively"; the "Cost and scope" levers list (scope tight / keep suite fast / cap with `--limit`) omits `--workers`. Not false, but the new lever is absent from the primary protection-coverage chapter. | FRICTION | Add `--workers=N` to the Tier-1 description (or the "Cost and scope" list) as the parallelism lever, deferring the precedence detail to `02`. |

## Intentional-simplification / accurate (not a gap)

- `15-type-protection-coverage.md:203-214` (the `external_gem_without_rbs` callout box, ADR-82 WD9).
  Accurate to `missing_gem_constant_index.rb`: the primary resolver is the target's bundle install
  tree (`bundle_gem_dirs`, `bundler.bundle_path:`); `Gem::Specification.find_by_name` is only a
  last-resort fallback that (per the class note, lines 28-36) sees rigor's own bundle, so the
  default-gem-home (`rbenv`/`mise`) case is largely invisible "by design". The "these holes keep the
  generic `engine_gap` cause … the label is missing, never wrong" claim matches the fail-open
  `unresolved_constant_fallback` (`expression_typer.rb:405-414`). Faithful.
- `15:176-201` tractability / provenance fields. Verified field-for-field against
  `protection_report.rb#to_h` and `dynamic_origin.rb`:
  - Six `dynamic_origin` values listed (`external_gem_without_rbs`, `framework_dsl_boundary`,
    `analyzer_budget_cutoff`, `explicit_untyped`, `inferred_return_untyped`, `unsupported_syntax`)
    = `DynamicOrigin::CAUSES` exactly.
  - Tractability mapping (`add_rbs` ← external-gem/explicit-untyped; `enable_plugin` ←
    framework-dsl; `engine_gap` ← budget-cutoff/inferred-return-untyped/unsupported-syntax) =
    `DynamicOrigin::TRACTABILITY` exactly.
  - JSON `add_a_type_here[].dynamic_origin` / `tractability` (omit-when-nil), `tractability_summary`,
    `cause_site_counts` all present in `to_h`. Faithful.
- `15:106-108` and `02:331-334` fused-view JSON (`mode` = `protection-fused`, `type_killed`,
  `test_killed`, `unprotected`, `protected_ratio`, per-file rows, `add_protection_here`) =
  `fused_protection_report.rb#to_h` exactly. Faithful.
- `02:311-313` mutation JSON (`mode`, `killed`, `survived`, `effectiveness_ratio`, per-file rows,
  `add_a_type_here`) = `mutation_protection_report.rb#to_h` exactly. Faithful.
- `03-configuration.md:131` `parallel.workers` (Integer, default `0`, "CLI `--workers` and
  `RIGOR_RACTOR_WORKERS` take precedence") and `03:43` `paths` default `["lib"]` — both accurate;
  precedence chain matches `02:609` and `coverage_command.rb` / `CheckRunnerFactory.resolve_workers`.
- `12-caching.md:110-116` `--workers=N` concurrency note is generic cache-safety text; now *more*
  true given coverage also forks, no correction needed.
- `17-driving-improvement.md` — references `rigor coverage --protection` only at the workflow level;
  no flag-level claims to contradict. Clean.

## Verdict

The coverage/CLI chapters are semantically faithful on all the load-bearing surfaces — the ADR-82
WD9 provenance/tractability labels and every JSON field name match the implementation exactly, the
config keys and defaults are correct, and no chapter still carries the retired "coverage requires a
path" claim (the PR #67 fallback to config `paths:` is verified working). The only drift is
**omission of PR #67's `--workers` flag from `02`'s coverage flag reference** (MISLEADING — the one
place billed as complete) and the un-surfaced new path-fallback and parallelism in `02`/`15`
(FRICTION). No ERROR-level inaccuracies found; all fixes are additive one-liners, no prose depth
required.
