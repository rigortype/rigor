# slim — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 27 (0 parse errors) |
| expressions | 4861 |
| precision | 57.48% (precise 2794 / opaque 2067) |
| protection | 34.25% (286 protected / 549 unprotected) |
| cause_site_counts | inferred_return_untyped 215, none 175, unsupported_syntax 148, explicit_untyped 11 |
| tractability | engine_gap 363, add_rbs 11 |

Opaque split: local reads 524 (def_param 311, block_param 85, assigned_local 128), calls 854
(receiver already-Dynamic 522, implicit_self 227, precise-receiver 105), ivar reads 163.

## The Temple boundary, mislabeled (attribution artifact worth fixing)

slim is a thin layer over Temple: `Slim::Engine < Temple::Engine`, every pass `< Temple::Filter`,
`Grammar extend Temple::Grammar`, and options/dispatch (`options`, `define_options`, `use`,
`register`, `after`, `before`, `set_options`, `on_*` visitor sends) all come from Temple, which ships
no RBS. In haml this surface is labeled `external_gem_without_rbs` (30 sites); in slim it reports as
ZERO — because **slim's checkout has no Gemfile.lock**, and the missing-gem-constant index
(rigor lib/rigor/environment/missing_gem_constant_index.rb) is lock-driven, so unresolvable
`Temple::*` constants fall through to generic `unsupported_syntax` (148 sites, 27% of unprotected —
the family's highest). Substance: category B/E (no-RBS gem + load-time DSL); attribution: a G-grade
artifact — the cause taxonomy silently degrades without a lockfile.

## Case list

| key | sites | cat | mechanism |
| --- | --- | --- | --- |
| Temple DSL surface (implicit-self `options` 46, `define_options` 16, `use` 10, `register` 9, `filter` 8, `set_options` 5; pairs `singleton(Slim::Engine)#after/before/set_options` 7) | ~100 | E/B | methods inherited from Temple mixins / Engine DSL; gem has no RBS. ex logic_less.rb:6, command.rb:6 |
| Grammar DSL (`<<` 46, `\|` 8 unsupported-origin sites) | 54 | E | `Expression << [:slim, ...] \| ...` — `Temple::Grammar` constants with overloaded `<<`/`\|`; unmodelable without the gem. grammar.rb:8-20 |
| visitor params (`on_html_attr(name, value)`: `value[0]`, `options[:merge_attrs][name]` — the `[]` 122-site cluster) | 122 | A/E | `on_*` visitor methods receive S-expression arrays as untyped params (Temple dispatches via send) — param-sourced; ADR-67 territory with a Temple-shaped call graph. code_attributes.rb:21 |
| Hash[Dynamic,Dynamic]#[] / #[]= / #delete | 41 | C | command-line options hash and embedded-engine option hashes. command.rb:85 |
| ""?#<< | 7 | D | optional receiver over a constant-string type — `String#<<` is core RBS; nil branch is bot; join is sound. embedded.rb:12 |
| String?#size / #include? / #empty? | 8 | D | optional-receiver refusal on core String methods. parser.rb:247, :356, :434 |
| Array[Dynamic]?#last / #<< / #[] | 10 | D+C | optional-receiver refusal stacked on Dynamic elements. parser.rb:204, embedded.rb:26 |
| Array[Dynamic] \| nil \| non-empty-array#last / #size | 5 | D | union-with-nil receiver dispatch refused; all non-nil arms answer identically. parser.rb:169 |
| Thread#[] / Thread#[]= | 4 | B | core RBS declares `Thread#[]` untyped — honest. include.rb:24 |
| implicit-self compile / unique_name / parse_text_block | 38 | A | visitor recursion over param-sourced sexps; `@unique_name` counters — ADR-67/58. |
| dynamic-receiver calls | 522 | C | propagation ([] 123, << 47, last 28 …) downstream of sexp params and option hashes. |
| def/block param reads | 396 | A | ADR-67 (closed). |
| ivar reads | 163 | A | ADR-58. |

## Verdict

slim's opacity is structurally Temple's: an untyped S-expression IR walked by visitor methods whose
params can never type without either Temple RBS or a Temple plugin (E). Engine-mechanism yield here
is small but consistent with the family: optional/union-receiver refusal (~30 sites) is the only
clean D. The transferable finding is the lockfile-gated cause attribution: no Gemfile.lock means
`external_gem_without_rbs` silently becomes `unsupported_syntax`, inflating the "unmodeled construct"
lane by ~5x for any bare-checkout survey target.
