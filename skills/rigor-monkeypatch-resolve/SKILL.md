---
name: rigor-monkeypatch-resolve
description: |
  Resolve a cluster of `call.unresolved-toplevel` / `call.undefined-method` diagnostics that are really the project's own monkey-patches (core-extension files that add methods with literal `def`) by wiring them into `pre_eval:` so Rigor pre-evaluates them and learns the added methods. Triggers: "Rigor flags methods my core-ext adds", "undefined-method on my own monkey-patch", "set up pre_eval", "lots of unresolved-toplevel from my lib/core_ext". NOT for dynamically-generated methods (define_method / method_missing / class_eval heredocs) — those need a plugin (use rigor-plugin-author) — and NOT for an external gem with no RBS (use rigor-rbs-setup).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Monkeypatch Resolve

When a project adds methods to existing classes in its own files — the
classic `lib/core_ext/*.rb` `class String; def squish; …; end` pattern —
Rigor does not see them unless told to, so every call to the added method
fires `call.undefined-method` (or `call.unresolved-toplevel` for a
top-level helper). `pre_eval:` ([ADR-17](https://github.com/rigortype/rigor/blob/master/docs/adr/17-monkey-patch-pre-evaluation.md))
fixes this: it pre-evaluates the listed project files and registers every
method they define with a **literal** `def` / `def self.`.

## When to use

- `rigor triage` shows a cluster of `call.undefined-method` /
  `call.unresolved-toplevel` whose receiver is a core class the project
  monkey-patches (or a top-level helper the project defines).

## When NOT to use

- The methods are **generated dynamically** (`define_method` with a
  computed name, `method_missing`, a `class_eval <<~RUBY … def #{name}`
  heredoc). `pre_eval:` walks for *literal* `def`s and will not find
  them — that residue is a `rigor-plugin-author` job.
- The cluster is on a **third-party gem** with no RBS — that is
  `rigor-rbs-setup`.

## Procedure

### Phase 1 — confirm it is a monkey-patch cluster

```sh
rigor triage --format json
```

Look at the `selectors` / `hotspots`: a cluster keyed on a core receiver
(`String#squish`, `Integer#…`) or a top-level helper, all pointing back
to a file in your project that defines them. Open that file and confirm
the methods are written as literal `def` / `def self.`.

### Phase 2 — wire the file(s) into `pre_eval:`

Add the defining file paths to `pre_eval:` in `.rigor.dist.yml` (paths
are resolved relative to the config file):

```yaml
pre_eval:
  - lib/core_ext/string.rb
  - lib/core_ext/integer.rb
```

List the **files that contain the `def`s**, not the call sites.

### Phase 3 — verify the cluster cleared

```sh
rigor check
```

The `call.undefined-method` cluster on those methods should be gone. If
some survive, those specific methods are almost certainly
**dynamically generated** — `pre_eval:` cannot reach them, and the
durable fix is a project plugin (hand off to `rigor-plugin-author`). A
genuine typo (a real undefined method) correctly keeps firing — do not
add it to `pre_eval:`.

## Next step

Re-run `rigor skill describe`. With the monkey-patch noise gone, the
remaining diagnostics are a cleaner target for `rigor-baseline-reduce`
or `rigor-protection-uplift`.
