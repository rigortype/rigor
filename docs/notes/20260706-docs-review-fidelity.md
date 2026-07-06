# Docs review — L1 fidelity cycle (manual operational chapters)

Status: review findings ledger (the [`rigor-docs-review`](../../.claude/skills/rigor-docs-review/SKILL.md)
battery, L1 真 layer). 2026-07-06, Rigor v0.2.7 (`[Unreleased]`). This is the **first cycle** of the
docs review battery — the L0 mechanical gate (`make docs-check`) was green going in.

## Scope + method

L1 fidelity over the manual's operational-claim chapters, run as three independent-context
subagents in parallel, each checking every non-mechanically-verifiable claim against the **real CLI
output** (`exe/rigor <cmd> --help` through the flake) and the **implementation** (`lib/rigor/…` + the
governing ADRs). An intentional simplification was not counted as drift — only accidental inaccuracy
(the doc asserts ¬X where the code does X). Every finding below was re-verified against the code
before applying.

| Reviewer | Chapters | Ground truth |
| --- | --- | --- |
| 1 | `02-cli-reference`, `11-ci` | per-subcommand `--help`, `CLI::HANDLERS`, `DiagnosticFormats`, `CiDetector`, ADR-51 |
| 2 | `03-configuration`, `04-diagnostics` | `Configuration::DEFAULTS`, `SeverityProfile::PROFILES`, `RuleCatalog::ENTRIES`, `CheckRules::ALL_RULES` |
| 3 | `12-caching`, `06-baseline`, `15-type-protection-coverage` | `Cache::*`, `Analysis::Baseline`, `coverage_command.rb`, `DynamicOrigin`, ADR-45/54/22/63/75/82 |

## Findings (verified) + fixes applied

| Chapter | Severity | Finding | Proof | Fix |
| --- | --- | --- | --- | --- |
| `04-diagnostics.md` (severity-profile table) | **ERROR** | "`strict` — Every rule is an `error`." is false. | `SeverityProfile::PROFILES[:strict]` maps `call.self-undefined-method → :off` and `flow.unreachable-clause → :warning`. | Reworded to "Nearly every rule … the exceptions are …". |
| `15-type-protection-coverage.md` (`dynamic_origin` field) | **ERROR** | The cause set is enumerated as 5 values; the field has 6. | `DynamicOrigin::CAUSES` includes `inferred_return_untyped` (the ADR-82-era dominant real-app cause, → `engine_gap`), absent from the chapter. | Added `inferred_return_untyped` to the enumeration and to the `engine_gap` tractability bullet (as the inference-gap case: untyped param / unbound ivar). |
| `06-baseline.md` (`--baseline-strict`) | MISLEADING | Documented as failing only "when the baseline *grows*". | `check_command.rb#baseline_strict_violation?` (comment L152-156) fails on **any** drift, including *deficit* drift (baseline looser than code). | Reworded to "fails on any baseline drift" with the excess/deficit split. |
| `04-diagnostics.md` (catalogue intro + `rigor explain` claim) | MISLEADING | Claims `rigor explain` + `documentation_url` cover "any ID" / "each rule", but `rbs_extended.unsatisfied-conformance` — listed in the catalogue — is not a built-in. | It lives only in `SeverityProfile::PROFILES`, not `RuleCatalog::ENTRIES` / `CheckRules::ALL_RULES`; `rigor explain` returns "Unknown rule" and `documentation_url` is nil for it. | Qualified the claims to "built-in rule" and noted the one `rbs_extended`-family exception carries no `rigor explain` entry / `documentation_url`. |

`make docs-check` stays green (96 examples) after the edits.

## Clean (no drift found)

- **`02-cli-reference.md` — high fidelity.** Every subcommand in `CLI::HANDLERS` and every checked flag
  matches the real `OptionParser` output (incl. the `type-of` three-arg form, the seven MCP tool
  names, coverage/fused JSON field names, `--test-command` default + no-shell exec, exit codes
  0/1/64, and the honest "`--log` accepted but not yet wired" LSP caveat).
- **`11-ci.md` — high fidelity.** The six CI-native `--format` values, the full per-format
  severity-mapping table, and the CI auto-detection tiers are byte-accurate against
  `diagnostic_formats.rb` + `ci_detector.rb` + ADR-51. **The design note's predicted ADR-51
  follow-through gap did not materialize** — the CI chapter was kept in sync.
- **`03-configuration.md`** — all `DEFAULTS` keys/values, discovery order, `includes:` layering, and
  the six config-validation warning strings match the code. **`12-caching.md`** — every invalidation
  input, default, flag, and the incremental-snapshot-keys-on-roots claim match `Cache::*`.
- **`04-diagnostics.md` (rest)** — the 19 built-in rules' firing conditions, evidence tiers, and the
  `--format json` field table match `RuleCatalog` + `Diagnostic#to_h` exactly.

## Not applied (nitpicks / out of scope)

- Illustrative version pins `0.2.6` in `02-cli` / `11-ci` vs the current `0.2.7` — intentional
  examples, not drift; left as-is.
- Whether to promote `rbs_extended.unsatisfied-conformance` into `RuleCatalog::ENTRIES` (so it gains
  `rigor explain` + a `documentation_url`) is a **code** decision outside this doc-fidelity pass — the
  doc now describes the actual behaviour. Flag for a future `RuleCatalog` review if desired.

## Next (battery continuation)

- **L2 伝** (reader lenses), **L3 簡** (bloat), **L4 整** (copyedit) over the same chapters, then a
  **handbook-vs-spec-corpus fidelity** pass (this cycle covered the manual only). Run sequentially —
  later layers read the corrected text.
