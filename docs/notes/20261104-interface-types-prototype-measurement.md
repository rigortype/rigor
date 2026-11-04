# RBS interface types — prototype measurement for ADR-130 (#929)

Status: measurement note, 2026-11-04, engine at `0a53fe62e`. It grounds
[ADR-130](../adr/130-interface-typed-values-dispatch-under-untyped-parity.md) and binds nothing.

**Result (A-only with parity, the proposal).** An interface value reads as `untyped` to every site and
resolves its declared members at dispatch. That rule added **no** diagnostic row on any of these corpora:

- `lib`;
- 48 plugin and example trees;
- fourteen survey targets.

The two exceptions are both out-of-scope differences:

- Rows that name a scratch path change between runs; each is the same row on both arms.
- The `dump_type` text in the fixtures changes, which is the intended precision.

Every one of the independent review's seven repros fires without parity and is silent with it.

**First draft (superseded), without parity.** That prototype also reported no new diagnostic over the
same trees, but the seven repros show it was not safe: the zero was an artefact of what the corpus
happens to contain.

**Assignability (half B, now deferred).** It added 3 rows at its proposed default, all of them false
positives. With the standard union reading it added 20 on `lib`, also all false positives.

## The prototype

The prototype is the local branch `interface-proto` in the `interface-assignability` worktree. It is
not pushed. Its commits on `0a53fe62e`:

| SHA | What it adds |
| --- | --- |
| `89d12edbb` | Carrier, half A dispatch, half B oracle |
| `0afcfa73d` | Reach counters |
| `8b980c6b2`, `41869d92b` | Every-member union reading for half B |
| `b9011b6ac` | Root-class `maybe` for half B |
| `b7e7d73d9` | **The parity predicate and core-alias erasure**: the ADR's proposal |

`RIGOR_PROTO_IFACE` selects the behaviour:

- `a`: half A;
- `b`: half B;
- `bu`: half B with the standard union reading;
- `ac`: half A carrying the core conversion aliases.

`RIGOR_PROTO_REACH=<file>` writes the counters.

The parity predicate is `Type::Combinator.untyped?`: true for `Dynamic[top]` and `Dynamic[Interface]`. The
family of sites routed through it was re-derived from `lib/` with two patterns:

- `static_facet.is_a?(Type::Top)` and `facet.is_a?(Type::Top)`;
- `== Combinator.untyped`, `equal?(Combinator.untyped)`, `== untyped` and `equal?(untyped)`.

| Site | Form | Purpose |
| --- | --- | --- |
| `type/combinator.rb:55` | facet `Top` | `Combinator.dynamic`'s own fold to `untyped` (kept: the constructor) |
| `inference/method_dispatcher/imprecise_argument.rb:23`, `:28` | facet `Top` | overload selection's imprecise-actual passes |
| `inference/method_dispatcher/facet_distribution.rb:122` | facet `Top` | member-wise selection over a `Dynamic` facet |
| `inference/untyped_rejoin.rb:60` | facet `Top` | the #1840 rejoin |
| `inference/statement_evaluator.rb:8742` | facet `Top` | ADR-67 WD3's inferred-parameter override |
| `inference/statement_evaluator.rb:3256` | `== untyped` | the `$_` check |
| `inference/statement_evaluator.rb:4023` | `equal?(untyped)` | `for` element fallback |
| `inference/method_dispatcher.rb:198`, `:829` | facet `Top` | `EXPLICIT_UNTYPED` origin; boundary-cross report |
| `inference/method_dispatcher/rbs_dispatch.rb:1918` | facet `Top` | the untyped-argument test in RBS dispatch |
| `inference/method_dispatcher/self_substitute.rb:107` | facet `Top` | `self` substitution's untyped type arguments |
| `inference/unknown_store_widening.rb:168` | facet `Top` | the unknown-store gradual arm |
| `inference/narrowing.rb:1818` | facet `Top` | `match_dynamic_kind` |
| `inference/precision_scanner.rb:171` | facet `Top` | the precision lens's `dynamic_top` bucket |
| `inference/expression_typer.rb:1339` | `equal?(untyped)` | `Range` endpoint typing |
| `inference/expression_typer.rb:3535` | `equal?(untyped)` | the ADR-84 memo's top exemption |
| `inference/clause_widening.rb:60` | `== untyped` | clause widening |
| `inference/multi_target_binder.rb:305` | `== untyped` | multiple-assignment binding |
| `inference/block_auto_splat.rb:197` | `== untyped` | block auto-splat columns |

That is 21 tests at 20 sites. `imprecise_argument.rb` holds two, and all of them except the constructor's
moved to the predicate.

The facet readers have no arm for `Interface`, so for an `Interface` facet they answer what they answer for
`top`:

- `receiver_blind_block.rb:209`;
- `scope_indexer.rb:2858`;
- `block_auto_splat.rb:129`;
- `match_rebinding/operands.rb:105`;
- `effects/collector.rb:167`.

The exception is `rbs_dispatch.rb`'s `receiver_descriptor`, which is the dispatch path.

The core conversion aliases are `::int`, `::float`, `::range`, `::string`, `::array`, `::hash`, `::io` and
`::path`. Each is an alias from rbs core's `builtin.rbs` of the form `C | _ToC`. An interface reached through
one of them translates to `Dynamic[top]`.

## Method

**Differential.** `tool/engine_diag_diff.rb --base 0a53fe62e --head <proto>` ran each arm in a fresh process
with `--no-cache`.

- `lib` and the plugin and example trees used `--corpus 0a53fe62e`.
- The survey targets used `--corpus-dir` on private `rsync` copies, without `.git`, `node_modules` or the
  cache.
- **Every survey baseline was renamed away.** A baseline is count-keyed per file and rule, so one new firing
  in a file releases every baselined firing of that rule there.

**Survey set.** textbringer, rgl, kramdown, alba, mail, liquid, faraday, mangrove, haml, herb, net-ssh, yard
(the delegator- and `method_missing`-heavy target), redmine and mastodon.

- rails was dropped. Its environment fails to build 1,610 class definitions
  (`RBS::GenericParameterMismatchError` on `::Array`), so every call reads `Dynamic[top]` and the run
  measures nothing.
- `git status` was compared before and after on every original checkout, and none changed.

**Plugins.** `plugins/*/lib examples/*/lib` (48 trees) ran from the repository root, so `sig/` loads. #2681
already carries `base.rbs` types into hook blocks.

A probe plugin read these types under the parity head in mode `a`:

| Expression in the hook | Reads |
| --- | --- |
| `scope` | `Dynamic[Rigor::Plugin::_Scope]` |
| `scope.type_of(node)` | the 21-member `Rigor::Type::t` union |
| `scope.environment` | `Dynamic[Rigor::Plugin::_Environment]` |
| `scope.self_type` | `Rigor::Type::t \| nil` |

All four read `Dynamic[top]` on the base. An undeclared `scope.not_in_interface` reports nothing.

## The review's repros as fixtures

The fixture is `tmp/p4` in the worktree, with every parameter declared in `sig/r.rbs`:

- `R#mul`: `(arr * x).first`;
- `R#plus`, `#minus`, `#times`, `#pow`: `(1 + x).nan?` and its three siblings;
- `R#rejoin_if`, `#rejoin_case`: `x.to_str` after a nil / `String` branch;
- `R#facet`: a control that dumps `x.to_str`;
- `R2#over`: an interface parameter with project call sites.

It ran through `engine_diag_diff` with `--corpus-dir tmp/p4`:

| Base → head | Removed | Added |
| --- | --- | --- |
| `b9011b6ac` (no parity) → `b7e7d73d9` (parity) | the 7 repros (5 `call.undefined-method`, 2 `call.possible-nil-receiver`) | 0 |
| `0a53fe62e` (master) → `b7e7d73d9` | `dump_type: Dynamic[top]` ×2 | `dump_type: String` (`x.to_str` via `_ToStr`), `dump_type: Dynamic[_ToStr]` |

The parity head reports no diagnostic on the fixture other than the two `dump_type` rows. The `R2#over`
parameter reads `Dynamic[_ToStr]` with parity and `Dynamic[top]` on master. ADR-67 WD3 overrode neither,
so the fixture does not exercise the override branch. The predicate routes that branch, but no
measurement here proves it.

## Diagnostic delta

Rows are `[path, line, column, rule, message]`. "Added" and "removed" are head minus base.

| Corpus | Base rows | A with parity (`b7e7d73d9`, `a`): added / removed | A carrying core aliases (`ac`) | First draft A, no parity (`41869d92b`, `a`) |
| --- | ---: | --- | --- | --- |
| `lib` | 1 | 0 / 0 | 0 / 0 | 0 / 0 |
| plugins + examples (48) | 1 | 0 / 0 | — | 0 / 0 |
| textbringer | 86 | 0 / 0 | — | 0 / 0 |
| rgl | 17 | 0 / 0 | — | 0 / 0 |
| kramdown | 7 | 0 / 0 | — | 0 / 0 |
| alba | 0 | 0 / 0 | — | 0 / 0 |
| mail | 22 | 0 / 0 | — | 0 / 0 |
| liquid | 45 | 0 / 0 | — | 0 / 0 |
| faraday | 3 | 0 / 0 | — | 0 / 0 |
| mangrove | 2 | 0 / 0 | — | 0 / 0 |
| haml | 14 | 0 / 0 | — | 0 / 0 |
| herb | 21 | 0 / 0 | — | 0 / 0 |
| net-ssh | 20 | 0 / 0 | — | — |
| yard | 105 | 0 / 0 | — | — |
| redmine | 1,876 | 0 / 0 | — | — |
| mastodon | 2,967 | 0 / 0 | 2 / 2 (message text) | 2 / 2 (message text) |

How to read the table:

- Redmine's and Mastodon's runs each also list their `rbs.coverage.plugin-signature-stood-down` rows (3 and 4)
  as both removed and added. Those rows name the per-arm scratch path; they are the same rows.
- Mastodon's two `ac` rows are `app/lib/request.rb:323` and `:326`. They print `got Dynamic[_ToInt] | Integer`
  where master prints `got Dynamic[top] | Integer`. That is the core-alias rendering that ADR-130 WD4 avoids.

## Reach (parity head, mode `a`)

"Parity-predicate hits" counts the `Type::Combinator.untyped?` calls that answered `true` because the facet
is an interface: each is a site where the first draft's value fell out of an `untyped` leniency. The
"Top sites" column names the three sites with the most hits in that corpus.

| Corpus | Interface-receiver calls, declared / undeclared | Parity-predicate hits on an interface value | Top sites |
| --- | --- | ---: | --- |
| lib | 16 / 53 | 2494 | imprecise_argument.rb:28 1174; imprecise_argument.rb:23 774; facet_distribution.rb:122 400 |
| plugins | 299 / 4 | 599 | untyped_rejoin.rb:60 251; method_dispatcher.rb:198 234; statement_evaluator.rb:8742 54 |
| textbringer | 0 / 0 | 96 | imprecise_argument.rb:28 48; imprecise_argument.rb:23 32; facet_distribution.rb:122 16 |
| rgl | 0 / 0 | 0 | — |
| kramdown | 0 / 2 | 150 | imprecise_argument.rb:28 75; imprecise_argument.rb:23 50; facet_distribution.rb:122 25 |
| alba | 37 / 60 | 72 | imprecise_argument.rb:28 37; method_dispatcher.rb:198 15; imprecise_argument.rb:23 8 |
| mail | 0 / 6 | 29 | imprecise_argument.rb:28 10; untyped_rejoin.rb:60 10; self_substitute.rb:107 6 |
| liquid | 0 / 0 | 0 | — |
| faraday | 0 / 7 | 51 | imprecise_argument.rb:28 28; imprecise_argument.rb:23 12; facet_distribution.rb:122 6 |
| mangrove | 0 / 0 | 0 | — |
| haml | 0 / 0 | 0 | — |
| herb | 1 / 0 | 87 | imprecise_argument.rb:28 42; imprecise_argument.rb:23 28; facet_distribution.rb:122 14 |
| net-ssh | 0 / 0 | 0 | — |
| yard | 0 / 0 | 14 | imprecise_argument.rb:28 6; imprecise_argument.rb:23 4; facet_distribution.rb:122 2 |
| redmine | 0 / 12 | 204 | imprecise_argument.rb:28 94; imprecise_argument.rb:23 60; facet_distribution.rb:122 30 |
| mastodon | 0 / 0 | 84 | imprecise_argument.rb:28 42; imprecise_argument.rb:23 28; facet_distribution.rb:122 14 |

Totals across all corpora, by site:

| Site | Hits |
| --- | ---: |
| `imprecise_argument.rb:28` | 1,586 |
| `imprecise_argument.rb:23` | 1,016 |
| `facet_distribution.rb:122` | 521 |
| `untyped_rejoin.rb:60` | 305 |
| `method_dispatcher.rb:198` | 284 |
| `self_substitute.rb:107` | 93 |
| `statement_evaluator.rb:8742` | 75 |

The other 13 sites were not reached on these corpora. They are why slice 1 needs a fixture per site rather
than corpus evidence.

Without the core-alias erasure, the first draft's interface-receiver counts were higher, because core-alias
values reached dispatch. For example mail recorded 46 undeclared calls where it now records 6.


## Cost

Setup:

- `rigor check --no-cache`, one fresh process per arm.
- The parity head `b7e7d73d9` in mode `a`. The head also carries the reach counters, which are inert
  without their variable.
- The band is `pr_allocations_pct: 1` (`bench/thresholds.yml`).

| Corpus | Base allocations | Parity head (`a`) | First draft (`a`, `b9011b6ac`) |
| --- | ---: | --- | --- |
| Rigor `lib` (`engine_alloc_ab.rb`, frozen corpus) | 74,397,018 | +518,226 (+0.70%) | +276,922 (+0.37%) |
| Mastodon `app` (`--measure`) | 85,484,052 | +72,109 (+0.08%) | +68,365 (+0.08%) |
| Mastodon `lib` (`--measure`) | 30,804,152 | +10,588 (+0.03%) | +7,011 (+0.02%) |

The diagnostic count is equal on every arm: Mastodon `app` 2,868, `lib` 393, Rigor `lib` 1.

The parity head's extra cost on Rigor `lib` over the first draft is not attributed. The likely source is
the prototype's alias check, which builds `rbs_type.name.to_s`, a new String, on every alias translation.
The implementation would compare `TypeName` values instead. Wall time is noise on this host.

## First draft: half B (deferred)

Measured on `89d12edbb`–`b9011b6ac`, kept here for the deferred half's re-entry. Method:

- The argument rule's and return rule's declared types translated interfaces bare.
- A thread-local oracle answered `Acceptance`'s `Interface` handler.
  - Every public member on the RBS or source surface answered `yes`.
  - A member the undefined-method receiver-side chain proves absent answered `no`. The chain ran without its
    call-site-lexical arms.
  - Anything else answered `maybe`.

| Corpus | B added | B with the standard union reading (`bu`) |
| --- | ---: | ---: |
| `lib` | 0 | 20 |
| 48 plugin and example trees | 0 | — |
| textbringer | 3 | — |
| alba | 1, then 0 with the root-class rule | — |
| other ten 2026-11-04 targets (rails vacuous) | 0 | — |

Adjudication: every row is a false positive.

| Row | Cause |
| --- | --- |
| textbringer `buffer.rb:642`, `rectangle.rb:148:26`, `:148:39` | Wrong project signatures: `save_point: () -> Integer` and `save_excursion: () -> Array[untyped]`; both return their block's value. The base already fires on the same cause at `rectangle.rb:141`. |
| alba `layout.rb:53` | `check_and_return: (...) -> Object` widens `@body`, and its `String` guard sits in another method. |
| `lib` ×16 `File.expand_path(x, __dir__)` (`bu`) | Nullability: `__dir__` is `String?`. |
| `lib` ×2 `result << bytes.byteslice(...)` (`bu`) | Nullability: `byteslice` is `String?`. |
| `lib/rigor/effects/snapshot.rb:287` (`bu`) | Nullability of a project helper's return. |
| `lib/rigor/lens/plugins.rb:28` (`bu`) | `const_source_location`'s pair typed as `Array[String \| Integer]`. |

The half found no true positive. Its member-level oracle verdicts on `lib` were 1,276 `yes`, 494 `no` and
0 `maybe`, over 2,999 interface-parameter argument sites. A `no` on one arm of `String | _ToStr` is not a
firing. Allocation cost with A and B both on: +0.67% on `lib` and +0.18% on Mastodon `app`.

The review found that the oracle does not implement its own criterion: it drops the lexical arms, and the
chain misses #2792 and #2793. The re-entry conditions are in ADR-130 § "Deferred".

## Limitations

- Nine of the fourteen survey targets hold no interface-typed value in reach. Half A's evidence is `lib`,
  the plugins, alba and the fixtures.
- The prototype erases the core aliases with a thread-local flag around their expansion. The
  implementation needs a context field instead, because the closed-alias memo is keyed by the expansion.
- No fixture exercised ADR-67 WD3's override of an interface parameter (above).
- The instrument is `interface-proto` at `b7e7d73d9`. It stays local; the coordinator chose not to push it.
