# Fused protection (`--with-tests`) — broad survey sweep

Status: validation sweep + findings, authored 2026-06-17 against Rigor v0.1.19
(`[Unreleased]`, the ADR-69/70 fused-protection cycle). Runs
`rigor coverage --protection --mutation --with-tests [--include-dynamic --limit]` across a
broad set of `rigor-survey` targets and records the behaviour, the actionable signal it
surfaces, and the real-world adoption friction. Non-normative.

Grounding: [ADR-70](../adr/70-fused-protection-coverage.md) (the fused overlay),
[ADR-69](../adr/69-pluggable-mutation-substrate.md) (the oracle + `--include-dynamic`
selector), and [`20260617-type-guided-mutation-testing-strategy.md`](20260617-type-guided-mutation-testing-strategy.md)
(the strategy + first validation). Data gathered by four parallel sub-agents over isolated
per-project bundles.

## Method

Per target: isolated `bundle install`, then a **matched (source file, single green test
file)** pair — the test file must pass standalone on the dev Ruby (4.0.5). For each pair,
run the overlay twice with `--format json`: **biteable** (default — concrete-type sites
only) and **`--include-dynamic --limit 40`** (every dispatch site, Dynamic included, capped).
The matched single-test scope keeps each suite run fast and sidesteps the "whole suite must
be green" problem; the trade-off is that `unprotected` over-reports versus the full suite
(a mutation a *different* test would catch shows unprotected) — correct-by-construction.

## Coverage

**13 targets attempted → 12 clean fused runs, 1 blocked.** The test (dynamic) axis fired on
**every** clean target (`test_killed > 0`); **zero false positives**, **zero crashes**, and
**every `lib/` tree restored byte-for-byte** (the oracle's `ensure`). The bundler-env strip
([`dc480068`](#)) held across all targets.

## Results

| target | fw | source file | biteable (sites/type/test/unprot) | `--include-dynamic` (sites/type/test/unprot) |
| --- | --- | --- | --- | --- |
| faraday | rspec | `utils.rb` | 14 / 8 / 0 / **6** | 40 / 7 / 20 / **13** |
| faraday | rspec | `adapter_registry.rb` | 4 / 4 / 0 / 0 | 10 / 5 / 5 / 0 |
| haml | minitest | `attribute_parser.rb` | 6 / 4 / 2 / 0 | 39 / 5 / 34 / 0 |
| haml | minitest | `ruby_expression.rb` | 2 / 2 / 0 / 0 | 12 / 3 / 9 / 0 |
| liquid | minitest | `lexer.rb` | 76 / 75 / 1 / 0 | 40 / 24 / 14 / **2** |
| liquid | minitest | `condition.rb` | 21 / 5 / 11 / **5** | 40 / 4 / 29 / **7** |
| hamlit | minitest | `attribute_parser.rb` | 6 / 2 / 4 / 0 | 39 / 3 / 36 / 0 |
| hamlit | minitest | `ruby_expression.rb` | 2 / 0 / 2 / 0 | 12 / 1 / 11 / 0 |
| rubocop-ast | rspec | `token.rb` | 2 / 2 / 0 / 0 | 40 / 1 / 39 / 0 |
| rubocop-ast | rspec | `processed_source.rb` | 11 / 6 / 5 / 0 | 40 / 1 / 31 / **8** |
| mail | rspec | `utilities.rb` | 27 / 9 / 11 / **7** | 22 / 1 / 16 / **5** |
| mail | rspec | `parts_list.rb` | 17 / 7 / 2 / **8** | 40 / 7 / 6 / **27** |
| rgl | minitest | `dijkstra.rb` | 11 / 11 / 0 / 0 | 40 / 11 / 26 / **3** |
| rgl | minitest | `base.rb` | 9 / 8 / 1 / 0 | 40 / 5 / 18 / **17** |
| erubi | minitest | `erubi.rb` | 32 / 12 / 18 / **2** | 40 / 3 / 34 / **3** |
| tdiary-core | rspec | `core_ext.rb` | 52 / 23 / 22 / **7** | 40 / 12 / 12 / **16** |
| algorithms | rspec | `search.rb` | 17 / 4 / 13 / 0 | 23 / 4 / 19 / 0 |
| mangrove | rspec | `option.rb` | 3 / 0 / 3 / 0 | 40 / 0 / 20 / **20** |
| jbuilder | minitest | `jbuilder.rb` | 9 / 9 / 0 / 0 | 40 / 8 / 31 / **1** |
| **parser** | minitest | — | **BLOCKED** | — |

(`--include-dynamic` site counts capped at the `--limit 40` sample; ratios there are
estimates.)

## Findings

**1. The test axis works on real code, everywhere.** `test_killed` fired on all 12 clean
targets (1–39 per file). Three regimes appear:

- **Type-dominant** (well-typed numeric/String code): `liquid/lexer.rb` 75/76 type-killed,
  `rgl/dijkstra.rb` 11/11, `jbuilder.rb` 9/9 biteable. The static net already holds.
- **Test-dominant** (Dynamic-receiver code the type checker can't bite): `hamlit/ruby_expression.rb`
  biteable type=0 → **both** caught by tests; `rubocop-ast/token.rb` 0→39 test-killed under
  `--include-dynamic`. Here a test is the only protection, and the fused map *shows* it.
- **Genuinely-gapped**: `faraday/utils.rb` (0.57), `mail/parts_list.rb` (0.53),
  `liquid/condition.rb` (0.76), `tdiary/core_ext.rb` (0.87) — sites neither axis protects.

**2. `--include-dynamic` is where the headline value lands.** It widens the denominator from
*biteable* sites to *all* dispatch sites and consistently surfaces the test axis: e.g.
`haml/attribute_parser.rb` 6→39 sites, test-killed 2→34; `rubocop-ast/token.rb` 2→40,
0→39. The "a `Dynamic` site guarded only by a test" cell is the dominant outcome on
real-world dynamic code — invisible to the biteable view.

**3. Zero false positives — the unprotected sites are real, and they cluster.** Every
`unprotected` site the sub-agents hand-checked was a genuine gap. The taxonomy of "add a
type **or** a test here":

- **Untested method bodies** — helpers the scoped test never calls: faraday
  `basic_header_from`/`normalize_path`/`build_url` (`#pack`, `#delete!`, `#start_with?`),
  mail `inspect_structure` (`PartsList.new`, `#content_type`), liquid `Condition#inspect`
  (`#join`).
- **Unreached conditional / error branches** — `#raise` re-raises in `rescue` (liquid lexer
  :168, rgl base :155), version-dispatch arms (rubocop-ast `parser_engine`/`ruby_version`
  case, erubi `RUBY_VERSION >= '1.9'` in a `LoadError` rescue).
- **Dynamic-receiver collaborators** — external-gem objects (rgl `PairingHeap::MinPriorityQueue`),
  framework/const facades (`Mail.random_tag`), duck-typed params/visitors (rubocop-ast
  `token`, rgl `@visitor`), and **metaprogramming DSLs** (mangrove's Sorbet `sig { returns … }`
  / `params` / `override` — neither types nor example-tests exercise them, a true signal).

**4. Cost.** Per-run wall 2–25 s, scaling with `(mutations measured) × (scoped-test
runtime)`. `--limit 40` bounded `--include-dynamic` effectively; the larger files
(`attribute_parser.rb` 39 sites) hit ~24 s. Confirms changed-files scoping + a fast scoped
test + `--limit` are the right cost levers.

## Friction taxonomy (adoption barriers — all environmental, none a Rigor bug)

The sweep's second deliverable: what stops `--with-tests` from "just working" on a fresh
checkout. None are defects in the overlay; they are the cost of needing a *green test
command*.

- **Build / codegen prerequisites (the hardest).** A project whose tests can't even load
  without a build step: **parser** (BLOCKED — checked-in lexer absent, needs `ragel ~>6.7`
  + `ostruct`, neither in the shell), **rubocop-ast** (`rake generate` racc/oedipus-lex
  codegen), **hamlit** (`rake compile` native ext + `-rtest_helper`). Once built, the
  overlay ran clean (the build artifacts are gitignored, so source stayed clean).
- **Coverage-floor non-zero exit** (faraday). `spec_helper` enforces SimpleCov
  `minimum_coverage 84`, so a single-file run exits non-zero *though green* → the
  green-precondition trips. The error message already steers toward "a plain pass/fail
  runner"; the sub-agent bypassed it with a `SimpleCov.start`-stubbing runner.
- **Ruby-4.0 bundled-gem cascade** (tdiary-core). Native `nokogiri` (no arm64-darwin25
  precompiled for the locked version) + extracted-stdlib gems (`cgi`/`pstore`/`rss`/`csv`/
  `ostruct`) had to be added/updated before the suite loaded.
- **Non-default / missing Gemfile + the no-shell `--test-command`** (erubi, jbuilder — a
  *new* finding). `--test-command` is `Shellwords.split` → `system(*argv)` with **no
  shell**, and the oracle wraps it in `Bundler.with_unbundled_env`. So an inline
  `BUNDLE_GEMFILE=… bundle exec …` prefix breaks two ways: the env-assignment is taken as a
  literal `argv[0]` (no shell to interpret it), and `with_unbundled_env` would strip it
  anyway. Reliable workarounds: **`bundle config set --local gemfile PATH`** (persists in
  `.bundle/config`, survives the env strip) or wrap in **`bash -c '…'`**. Worth documenting;
  a future `--gemfile` pass-through is a possible ergonomics fix.

## Verdict

`--with-tests` is **sound and FP-free at survey scale**: 12/12 clean targets, the test axis
firing on every one, all `unprotected` verdicts adjudicated as genuine gaps, byte-for-byte
restoration throughout, no crashes. `--include-dynamic` is what makes the fused map worth
running on real (dynamic) Ruby — it is where the test-protection signal actually lives. The
binding constraint on adoption is **not** the analyzer but **getting a green test command**:
build prerequisites, coverage-floor exits, Ruby-version gem cascades, and non-default
Gemfiles. The one concrete, cheap follow-up the sweep earns is documenting the
`bundle config set --local gemfile` pattern for the no-shell `--test-command` (done in the
CLI reference); a `--gemfile` pass-through and coverage-based test selection (run only the
tests covering the file, for completeness *and* cost) remain the ADR-46/71 follow-ups.
</content>
