# Work-multiplier census (measurement instrument, not for merge)

The instrument behind `docs/notes/20261104-work-multiplier-census.md`. It prepends counters onto the
engine and runs `rigor check` in-process, so it measures the tree named by `RIGOR_LIB`, nothing else.
It lives on the `work-census-harness` branch so a later question about the same subsystem can rerun it.

## What it counts

- `MODE=phases` — exclusive thread CPU per engine phase (discovery, the `ScopeIndexer.index` stages,
  the rule walk, callee-body evaluation), plus how many callee bodies each phase started.
- `MODE=census` — everything in `phases`, plus:
  - `ExpressionTyper#type_of` and `StatementEvaluator#evaluate` calls per node and per identical
    `(scope object, node)` pair, by node class and by block-nesting depth;
  - `Scope` constructions and `Type::Combinator.union` calls per phase;
  - return-memo consults, hits and computes, each compute classed by whether its def or key was seen
    before (`first`, `new_key`, `seen_key_unstored`, `seen_key_refused`) and by argument shape
    (`noargs`, `alldyn`, `typed`, `cycle`), with exclusive CPU per class;
  - how many body evaluations a key that dropped unread parameters, or dropped the receiver, would
    have served, and how often that key's stored result disagreed (the soundness check of the proxy);
  - per-file CPU against AST node count (`files`).
- `MEMO=1` — a PROTOTYPE `type_of` memo keyed on `(scope identity, node identity)`, bypassed under a
  threaded operand table or a key-presence guard walk, cleared per file. It has no store gate and is
  unsound inside an ADR-55 fixpoint (the same body scope is evaluated up to three times); it exists
  only to size the lever.

## Running it

Run from the target's directory so its configuration and plugins resolve, with this checkout's bundle:

```sh
nix develop --command bash -c 'cd <target> && BUNDLE_GEMFILE=<rigor>/Gemfile RIGOR_LIB=<rigor>/lib \
  MODE=census OUT=/tmp/census.json bundle exec ruby <rigor>/tool/work_census/work_census.rb \
  check --no-cache --workers=0 --format json < /dev/null > /tmp/diags.json'
```

`compare_diagnostics.py` diffs two `--format json` outputs (`<corpus>_base.out` / `<corpus>_memo.out`
in its own directory) and prints the CPU and allocation totals beside them. For an output-identity
check, run with `--no-baseline` and a `severity_profile: strict` configuration: with the survey
baselines on, only a handful of rows reach the output.

Counts are deterministic; CPU seconds are not, and the hooks themselves cost CPU in `census` mode.
Compare CPU only between alternated runs in one mode, and decide wall on CI Linux
(`docs/agents/measurement.md`).
