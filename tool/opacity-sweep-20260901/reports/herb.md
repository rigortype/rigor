# herb — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 42 (0 parse errors; bundled `sig/` via signature_paths) |
| expressions | 22027 |
| precision | 60.65% (precise 13359 / opaque 8668, of which top 56) |
| protection | 48.13% (1879 protected / 2025 unprotected) — best in the family |
| cause_site_counts | inferred_return_untyped 841, none 816, explicit_untyped 190, unsupported_syntax 172, external_gem_without_rbs 6 |
| tractability | engine_gap 1013, add_rbs 196 |

Opaque split: local reads 2779 (def_param 1342, block_param 465, assigned_local 972), calls 3457
(receiver already-Dynamic 2227, implicit_self 905, precise-receiver 325), ivar reads 320.

## Headline: declared types lost purely to `T?` receivers (incl. `&.`)

herb ships RBS (`sig/herb/token.rbs:13` declares `attr_reader value: String`), yet
`Herb::Token?#value` is the target's top pair (29 sites) and `Token?#location` adds 5:
the optional receiver alone discards the declared type. Worse, safe navigation does not rescue it —
repro (typeof_probe11): on `s : Saf?` BOTH `s.name` and `s&.name` answer Dynamic, though `&.` is the
easy case (`nil | Saf#name`). herb's analyzer code is written in modern `&.`-chain style
(`node.keywords&.plain`, `node.location.start.line` behind an `if node.location` guard —
render_analyzer.rb:1044-1048), so the unsupported_syntax cluster (`start` 43, `line` 33, `column` 27)
is these chains' propagation. Fix direction: `T?#m` and `T?&.m` dispatch as join over arms (nil arm =
bot for `.`, nil for `&.`) — it is the single highest-leverage mechanism in this target and recurs in
all seven.

## Case list

| key | sites | cat | mechanism |
| --- | --- | --- | --- |
| Herb::Token?#value / #location | 34 | D | optional-receiver refusal discarding bundled-RBS types (headline). ast/helpers.rb:11, engine/error_formatter.rb:179 |
| `&.` chains (start/line/column cluster, keywords&.plain) | ~103 | D | safe navigation answers Dynamic even when the non-nil arm is fully typed (repro typeof_probe11). render_analyzer.rb:1044-1048, cli.rb:559-560 |
| Hash#[] (bare) / Hash[Dynamic,Dynamic] variants | 40 | C | render-call option hashes. render_analyzer.rb:125 |
| hash-shape-union #[]= (`Hash[D,D] \| {}`, `Hash[Symbol,D] \| {file: D}`, `{}`, `{file_path: D}`) | 41 | G/D | `[]=` results mirror Dynamic RHS (G); the shape-union receivers additionally show union-dispatch refusal (D). cli.rb:675, render_analyzer.rb:1036 |
| singleton(Herb::Configuration)#load | 6 | D | `def load(project_path = nil)` (configuration.rb:213) — optional param disqualifies return inference (param-shape guard). herb.rb:101 |
| Array[String]?#first | 6 | D | optional-receiver refusal; would be `String?`. cli.rb:499 |
| union-of-JSON-scalars #dig | 4 | D | wide union receiver (Array \| FalseClass \| Float \| Hash \| ...) — dispatch refused instead of joining over arms that define dig. configuration.rb:81 |
| singleton(Herb)#configuration | 4 | A | `@configuration \|\|=` class ivar (closed thread). engine.rb:78 |
| Herb::Engine#src | 4 | A | attr_reader over ivar from optional-param initialize (ADR-58 + guard). cli.rb:692 |
| singleton(FileUtils)#mkdir_p | 3 | G | answers `top` (not Dynamic) — the RBS `void`-ish return maps to Top and the opaque bucket counts it; control `File.basename` → String. bootstrap.rb:39. The 56 `top`-tier exprs are this class of artifact. |
| Herb::AST::DocumentNode#accept | 3 | A | visitor `accept(visitor)` returns `visitor.visit_*` — param-sourced. engine.rb:159 |
| explicit_untyped lane (empty? 26, ! 19, config_path 11, to_json 8 …) | 190 | B | herb's own sig/ declares untyped members (e.g. config accessors) — the one large add_rbs lane in the family; tighten sig/. render_analyzer.rb:32,41 |
| implicit-self dimmed/bold/green/label/pluralize | ~140 | A/D | CLI color/format helpers — most take `(text)` (A, param-sourced); several have optional params (guard). |
| dynamic-receiver calls | 2227 | C | propagation ([] 312, count 85, each 72, puts 71 …) downstream of untyped config/JSON hashes and `&.` chains. |
| def/block param reads | 1807 | A | ADR-67 (closed). |
| ivar reads | 320 | A | ADR-58. |

## Verdict

herb proves the pattern the family predicts: give Rigor real signatures (bundled sig/) and the
residual opacity concentrates in TWO engine mechanisms — optional-receiver/safe-navigation dispatch
and the param-shape guard — plus a genuine add_rbs lane (its own sig's untyped members, 190 sites).
Also surfaced a metric artifact: void-returning stdlib calls land as `top` in the opaque bucket.
