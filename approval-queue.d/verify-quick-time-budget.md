# Bound verify-changed's mirror directory by a checked-in per-file time table, 20 s for --quick and 330 s for the default tier

- **PR:** [#3349](https://github.com/rigortype/rigor/pull/3349)
- **Issue:** [#3289](https://github.com/rigortype/rigor/issues/3289)
- **Class:** process
- **Precedent:** none — sets one
- **Decided:** 2026-11-19

## Background

`bin/verify-changed` selected a changed file's mirror directory only while it held at most 30 spec
files. ADR-116's splits took `spec/rigor/analysis/check_rules/` to 46 files, so an edit to
`check_rules.rb` ran none of that directory's specs, although they are cheap. Meanwhile `sig_gen/`
(25 files, over five minutes) and `mcp/` (2 files, ~300 s) ran whole. The issue asked for a time
bound and left open where the per-file times come from and what the budgets are.

## Options and trade-offs

- **Example count or file size as a proxy.** This needs no state and has no merge conflicts, but
  measured per-example cost ranges from 0.5 ms to 430 ms between directories, so the proxy
  misprices exactly the directories the bound exists for.
- **rspec's persistence file.** This is local state: it is absent on a fresh clone and differs
  between machines, so the selection would not be deterministic.
- **A checked-in table (taken).** It is honest, deterministic and offline. The risks are
  staleness and merge churn. A refresh keeps any row within a factor of two of its new value, and an
  unlisted spec is priced at a default at or above the 90th percentile, so no PR has to touch the
  table.
- **Budget for the default tier.** The default tier could use the same 20 s as `--quick`, but that
  would make the pre-push gate check less than the count bound did (`sig_gen/`, `mcp/`). It could
  instead be unbounded, which would add six minutes to a `cli.rb` push. 330 s is the smallest round
  figure that keeps every directory the old rule selected whole, so the gate checks nothing less.

## Decision

Use a table (`tool/spec_costs.tsv`, refreshed by `tool/spec_costs.rb`). Take specs cheapest
first, ties by path, after charging the same-named mirror spec. The budgets are 20 s for `--quick`
and 330 s for the default tier, and every spec left out is named together with its run command.

## To undo

Restore `mirror_dir_cap` in `bin/verify-changed` and its examples in
`spec/tool/verify_changed_spec.rb`, delete `tool/spec_costs.{rb,tsv}` and
`spec/tool/spec_costs_spec.rb`, and restore the `AGENTS.md` § Validation wording. To retune, change
the budget numbers in `bin/verify-changed`; the specs read them from there.
