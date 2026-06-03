# Baseline Key Derivation

`Rigor::Analysis::Baseline` filters a live diagnostic stream against a
recorded `.rigor-baseline.yml` so a project can adopt Rigor without fixing
every pre-existing finding at once ([ADR-22](../adr/22-baseline-and-project-onboarding.md)).
This page pins the **bucket-key derivation** — how a diagnostic maps to a
stored row — which is the durable contract a baseline file's format
depends on. The operational guide (generating, refreshing, editing the
file) is in the User Manual § "Baseline"; the design rationale (rule-id vs
message granularity) is in ADR-22 WD1.

Baseline filtering is the **last suppression layer**, applied after inline
`# rigor:disable` markers and after severity resolution
([diagnostic-policy.md](../type-specification/diagnostic-policy.md#severity-resolution)).

## Bucket key

A baseline row (`Baseline::Bucket`) is keyed by a tuple:

```
[ file, rule, message_regex ]
```

- `file` — the diagnostic's path **relative to the project root** (the
  working directory when `rigor` runs). Storing relative paths keeps the
  generated file portable across machines and checkout locations; a live
  diagnostic's absolute path is normalised to relative before the lookup.
- `rule` — the diagnostic's `qualified_rule`
  ([`diagnostic-shape.md`](diagnostic-shape.md)). A diagnostic whose
  `qualified_rule` is `nil` (an unsuppressible parse / internal error) or
  whose `path` is `nil` is **never** baselined.
- `message_regex` — `nil` in rule mode; a `Regexp` in message mode (below).

Each bucket also carries a `count` — the PHPStan-compatible number of
occurrences recorded for that key, so a baseline tolerates exactly the
recorded multiplicity and surfaces a regression when the count grows.

## Match modes

The `match_mode` selects the key granularity:

- **`:rule`** — the key's `message_regex` is `nil`, so every diagnostic for
  a `(file, qualified_rule)` pair contributes to one bucket regardless of
  message. The coarser, more churn-tolerant mode.
- **`:message`** — the key carries a `message_regex` derived from the
  diagnostic's message, so each distinct message gets its own bucket. The
  generator writes `Regexp.escape(message)` so the YAML round-trip matches
  the literal message; a user hand-editing the row MAY replace the escaped
  form with a looser pattern. The tighter mode — it distinguishes
  `undefined method 'foo'` from `undefined method 'bar'` under the same
  rule.

The stored file format version is `Baseline::CURRENT_VERSION` (`1`).
