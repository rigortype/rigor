# RBS interface types — prototype measurement for ADR-130 (#929)

Status: measurement note, 2026-11-04, engine at `0a53fe62e`. It grounds
[ADR-130](../adr/130-interface-typed-values-dispatch-under-untyped-parity.md) and binds nothing.

**Result (draft 3, the proposal).** The proposal scopes the facet to the `Rigor::Plugin` interfaces and adds
the parity predicate, the untyped union merge and the overload-shape rule. Measured on `lib`, the 48 plugin
and example trees and fourteen survey targets:

- Dispatch on added **no** diagnostic row, and **no** row was removed.
- The behavioural parity differential (dispatch off) was empty.
- With dispatch on, sig-gen output changed on the plugin trees. With dispatch off, which is how ADR-130 WD5
  runs sig-gen, it was byte-identical to master on `lib` and the plugin trees.
- Lens runs with dispatch on, as `check` does. It changes 15 plugin-tree return sites, and these are the
  intended precision.
- Three review rounds reproduced findings on earlier drafts: eleven false positives, and two structural
  divergences in nested joins. Every one is a fixture.
  - Each false positive fires on its draft's head and is silent on the final head.
  - Each join reads as master reads it.
- Allocations: +0.007% on `lib` and +0.005% on Mastodon `app`, after the attribution below.

The earlier drafts, kept for the record:

- **Draft 1** carried every interface as `Dynamic[_Foo]` without parity.
- **Draft 2** added parity for every interface.
- Both also read zero on the corpus, yet the reviews reproduced ten false positives between them. A zero on
  the corpus is therefore not evidence of safety here; the fixtures and the parity differential are.

## The prototype

The prototype is the local branch `interface-proto` in the `interface-assignability` worktree. It is not
pushed, and its head is `6037e728a`. Each commit sits on `0a53fe62e`:

| SHA | What it adds |
| --- | --- |
| `89d12edbb`, `0afcfa73d`, `8b980c6b2`, `41869d92b`, `b9011b6ac` | Draft 1: the carrier, dispatch, the half-B oracle and the reach counters |
| `b7e7d73d9` | Draft 2: the parity predicate and core-alias erasure, for every interface |
| `3410399da`, `992d583c6` | **Draft 3 (the proposal):** `Rigor::Plugin` scope, the untyped union merge, the overload-shape rule; then a counting merge for allocation |
| `6037e728a` | **Round 3:** union merge modulo facet erasure, nested inside Tuple, HashShape, Nominal and Union; a possibly-nil block-pass matches both shapes |
| `1e5972f66` (branch `interface-proto-d2-typename`) | Draft 2 with a `TypeName`-set alias check, for allocation attribution only |

`RIGOR_PROTO_IFACE` selects the mode:

- `a`: dispatch on;
- `an`: the carrier present, dispatch off (the parity differential);
- `b`, `bu`: half B.

`RIGOR_PROTO_REACH=<file>` writes the counters.

### Draft 3's rules as prototyped

- **Scope.** `translate_interface` carries the facet only when the interface's `TypeName` namespace path is
  `[:Rigor, :Plugin]`. Every other interface returns `Combinator.untyped`. This is a pure function of the
  name, so the closed-alias memo (keyed by expansion) is order-independent.
- **The predicate.** `Type::Combinator.untyped?` is true for `Dynamic[top]` and for `Dynamic[Interface]`. It
  replaces the site family below, which was re-derived from `lib/` with two greps:
  - `static_facet.is_a?(Type::Top)` and `facet.is_a?(Type::Top)`;
  - `== Combinator.untyped`, `equal?(Combinator.untyped)`, `== untyped` and `equal?(untyped)`.
- **The union merge.** `normalized_union_members` compares members modulo facet erasure (`merge_untyped_members`,
  `erase_facets`). The erasure rewrites `Dynamic[<plugin interface>]` to `Dynamic[top]` recursively inside
  `Tuple` elements, `HashShape` values, `Nominal` type arguments and unions. Members that are equal after
  erasure merge into the erased form, and a member alone in its class keeps its facet. The check runs only
  when some member bears a facet, and it allocates nothing otherwise.
- **The nil block-pass rule.** For `&expr`, where `expr` is a nil-bearing union or `Dynamic`, dispatch
  requires both the block-ful and the block-less shape. It answers only when the two returns agree;
  otherwise the call reads `untyped`. `&:sym` is never nil.
- **The overload-shape rule.** `interface_shape_accepted?` lets dispatch through an interface member
  resolve only when some overload takes the call's block presence, positional count and required
  keywords. Otherwise the tier declines and the call reads `untyped`.

| Site | Form | Purpose |
| --- | --- | --- |
| `type/combinator.rb:55` | facet `Top` | `Combinator.dynamic`'s own fold (kept: the constructor) |
| `inference/method_dispatcher/imprecise_argument.rb:23`, `:28` | facet `Top` | overload selection's imprecise-actual passes |
| `inference/method_dispatcher/facet_distribution.rb:122` | facet `Top` | member-wise selection over a `Dynamic` facet |
| `inference/untyped_rejoin.rb:60` | facet `Top` | the #1840 rejoin |
| `inference/statement_evaluator.rb:8742` | facet `Top` | ADR-67 WD3's inferred-parameter override |
| `inference/statement_evaluator.rb:3256` | `== untyped` | the `$_` check |
| `inference/statement_evaluator.rb:4023` | `equal?(untyped)` | `for` element fallback |
| `inference/method_dispatcher.rb:198`, `:829` | facet `Top` | `EXPLICIT_UNTYPED` origin; boundary-cross report |
| `inference/method_dispatcher/rbs_dispatch.rb:1918` | facet `Top` | untyped-argument test in RBS dispatch |
| `inference/method_dispatcher/self_substitute.rb:107` | facet `Top` | `self` substitution's untyped type arguments |
| `inference/unknown_store_widening.rb:168` | facet `Top` | the unknown-store gradual arm |
| `inference/narrowing.rb:1818` | facet `Top` | `match_dynamic_kind` |
| `inference/precision_scanner.rb:171` | facet `Top` | the precision lens's `dynamic_top` bucket |
| `inference/expression_typer.rb:1339` | `equal?(untyped)` | `Range` endpoint typing |
| `inference/expression_typer.rb:3535` | `equal?(untyped)` | the ADR-84 memo's top exemption |
| `inference/clause_widening.rb:60` | `== untyped` | clause widening |
| `inference/multi_target_binder.rb:305` | `== untyped` | multiple-assignment binding |
| `inference/block_auto_splat.rb:197` | `== untyped` | block auto-splat columns |

Two files hold two tests each (`imprecise_argument.rb` and `method_dispatcher.rb`), so the table's 20 sites
make 21 tests.

Some sites read a facet for its content: `receiver_blind_block.rb:209`, `scope_indexer.rb:2858`,
`block_auto_splat.rb:129`, `match_rebinding/operands.rb:105` and `effects/collector.rb:167`. None of them has
an `Interface` arm, so they answer as for `top`. The exception is `rbs_dispatch.rb`'s `receiver_descriptor`,
which is the dispatch path.

## Method

- **Differential.**
  - `tool/engine_diag_diff.rb --base 0a53fe62e --head 3410399da`, with each arm in a fresh process and
    `--no-cache`.
  - `lib` and the 48 plugin and example trees were analysed with `--corpus 0a53fe62e`, from the repository
    root so `sig/` loads.
  - The survey targets were analysed with `--corpus-dir` on private `rsync` copies, without `.git`,
    `node_modules` or the cache, and with every baseline renamed away. A baseline is count-keyed per file
    and rule, so one new firing in a file releases every baselined firing of that rule there.
- **Survey set.** textbringer, rgl, kramdown, alba, mail, liquid, faraday, mangrove, haml, herb, net-ssh,
  yard (the delegator- and `method_missing`-heavy target), redmine and mastodon.
  - rails was dropped: its environment fails to build 1,610 class definitions
    (`RBS::GenericParameterMismatchError` on `::Array`), so it measures nothing.
  - Every original checkout's `git status` was compared before and after; none changed.
- **Behavioural parity.** The same differential ran with `RIGOR_PROTO_IFACE=an`: the carrier present,
  dispatch off. The criterion is zero rows.
- **sig-gen and lens.** Each engine was archived with `exe/`, and `rigor sig-gen --format=json` and
  `rigor lens --format=json` were run over a corpus archive of `0a53fe62e`, base against head. The lens run
  over the plugin trees used a configuration whose `paths:` names them, because lens reports a file outside
  `paths:` as `outside_project`.

## Fixtures

The fixture is `tmp/p5` in the worktree. It declares four interfaces under `Rigor::Plugin` so the draft 3
scope applies:

- `_ProbeA` (`to_str`);
- `_ProbeB` (`to_s`);
- `_ProbeInt` (`to_int`);
- `_ProbeEach` (`each: () { (Integer) -> void } -> Array[Integer]`).

It reproduces the reviews' findings with those types:

| Method | Shape | Finding |
| --- | --- | --- |
| `mul` | `(arr * x).first` | review 1 |
| `plus`, `minus`, `times`, `pow` | `(1 + x).nan?` and siblings | review 1 |
| `rejoin_if`, `rejoin_case` | `x.to_str` after a nil / `String` branch | review 1 |
| `r3` | `x = f ? a : b`, then a nil / `String` case, then `x + "z"`, with two interface arms | review 2, severe 1 |
| `r3u` | the same, with an `untyped` arm | review 2, severe 1 |
| `e` | `xs.each.with_index { … }` | review 2, severe 2 |
| `mix` | an interface value joined with `String` (the other side of the union rule) | — |
| `facet` | a control: `x.to_str` resolves | — |

| Base → head (mode) | Removed | Added |
| --- | --- | --- |
| `b9011b6ac` (draft 1) → `3410399da` (`a`) | 10: 5 `call.undefined-method` (review 1), 4 `call.possible-nil-receiver` (review 1 ×2, `r3`, `r3u`), 1 `call.undefined-method` `with_index` | 0 |
| `b7e7d73d9` (draft 2) → `3410399da` (`a`) | 3: `r3`, `r3u`, `with_index` | 0 |
| `0a53fe62e` (master) → `3410399da` (`a`) | 5 `dump_type` texts | 5 `dump_type` texts: `Integer` for `_ProbeEach` block values, `Dynamic[Rigor::Plugin::_ProbeA] \| String`, `String` from `to_str` |
| `0a53fe62e` (master) → `3410399da` (`an`, dispatch off) | 2 `dump_type` texts | 2: the rendered `Dynamic[Rigor::Plugin::_ProbeA]` only |

**The other side of the union rule (`mix`).**

| Expression | master | draft 3, dispatch on | draft 3, dispatch off |
| --- | --- | --- | --- |
| `y` after `y = f ? a : s` | `Dynamic[top] \| String` | `Dynamic[Rigor::Plugin::_ProbeA] \| String` | `Dynamic[Rigor::Plugin::_ProbeA] \| String` |
| `y.to_str` | `Dynamic[top]` | `String`: each arm resolves, and the join is `String` | `Dynamic[top]` |

The `possible-nil-receiver` at `mix`'s `y + "z"` fires on master and on both modes alike. It is a master
reading of `Dynamic[top] | String` after a nil branch, and parity keeps it.

**Round 3 fixtures** (`tmp/p6`, on `Rigor::Plugin::_ProbeS` and `_ProbeEach`):

| Method | Shape | master | `992d583c6` (`a` and `an`) | `6037e728a` (`a` and `an`) |
| --- | --- | --- | --- | --- |
| `tup` | `f ? [a] : [b]` | `[Dynamic[top]]` | `[Dynamic[_ProbeS]] \| [Dynamic[top]]` | `[Dynamic[top]]` |
| `shape` | `f ? { k: a } : { k: b }` | `{ k: Dynamic[top] }` | `{ k: Dynamic[_ProbeS] } \| { k: Dynamic[top] }` | `{ k: Dynamic[top] }` |
| `shape` | then `h.merge(z: 1)` | `{ k: Dynamic[top], z: 1 }` | `Hash[:k \| Dynamic[top], Dynamic[top]]` | `{ k: Dynamic[top], z: 1 }` |
| `blockpass` | `xs.each(&blk)`, `blk : (^(Integer) -> void)?` | `Dynamic[top]` | `Array[Integer]` (`a`); `with_index` reports `call.undefined-method` | `Dynamic[top]`; silent |

Results through `engine_diag_diff`:

- `992d583c6` → `6037e728a` on `tmp/p6`: removes the `with_index` false positive and the three divergent
  `dump_type` texts.
- master → `6037e728a` on `tmp/p6`: 0 rows in both modes.
- On `tmp/p5`, `6037e728a` keeps the earlier results:
  - from draft 1, 10 removed and 0 added;
  - against master, only `dump_type` text differs.

**A plugin hook (probe).** Under draft 3 with dispatch on:

| Expression | Reads |
| --- | --- |
| `scope` | `Dynamic[Rigor::Plugin::_Scope]` |
| `scope.type_of(node)` | `Rigor::Type::t` (the 21-member union) |
| `scope.environment` | `Dynamic[Rigor::Plugin::_Environment]` |
| `scope.self_type` | `Rigor::Type::t \| nil` |

`scope.not_in_interface` reports nothing.

## Diagnostic delta (draft 3, `3410399da`)

The round-3 head `6037e728a` was re-run on `lib` and the 48 plugin and example trees, in both modes. It
read 0 added and 0 removed in every run. The survey targets hold no `Rigor::Plugin` value, so they were not
re-run.

Rows are `[path, line, column, rule, message]`. "Added" and "removed" are head minus base.

| Corpus | Base rows | Dispatch on (`a`): added / removed | Parity differential, dispatch off (`an`): added / removed |
| --- | ---: | --- | --- |
| `lib` | 1 | 0 / 0 | 0 / 0 |
| 48 plugin + example trees | 1 | 0 / 0 | 0 / 0 |
| textbringer | 86 | 0 / 0 | 0 / 0 |
| rgl | 17 | 0 / 0 | 0 / 0 |
| kramdown | 7 | 0 / 0 | 0 / 0 |
| alba | 0 | 0 / 0 | 0 / 0 |
| mail | 22 | 0 / 0 | 0 / 0 |
| liquid | 45 | 0 / 0 | 0 / 0 |
| faraday | 3 | 0 / 0 | 0 / 0 |
| mangrove | 2 | 0 / 0 | 0 / 0 |
| haml | 14 | 0 / 0 | 0 / 0 |
| herb | 21 | 0 / 0 | 0 / 0 |
| net-ssh | 20 | 0 / 0 | 0 / 0 |
| yard | 105 | 0 / 0 | 0 / 0 |
| redmine | 1,876 | 0 / 0 | 0 / 0 |
| mastodon | 2,967 | 0 / 0 | 0 / 0 |

How to read the table:

- Redmine's and Mastodon's runs also list their `rbs.coverage.plugin-signature-stood-down` rows (3 and 4)
  as both removed and added. Those rows name the per-arm scratch path and are the same rows; they are
  excluded from the counts above.
- Every survey target holds no `Rigor::Plugin` interface value, so draft 3 changes nothing there by
  construction. Those rows show the predicate and the union merge alone are neutral. The plugin trees are
  where the facet is live.
- Earlier drafts on the same set, mode `a`, all read 0 added and 0 removed, except Mastodon's two rows
  whose message text changed under core-alias carrying:
  - draft 1, `41869d92b`: `lib`, the plugin trees and twelve targets;
  - draft 2, `b7e7d73d9`: `lib`, the plugin trees and fourteen targets.

## sig-gen and lens

Both commands ran over a corpus archive of `0a53fe62e`. Lens JSON was compared with its `producer` block
(the engine digest) removed.

| Output | Dispatch on (`a`) | Dispatch off (`an`) |
| --- | --- | --- |
| `sig-gen --format=json lib` | identical | identical |
| `sig-gen --format=json` over the 48 plugin and example trees | **13 of 1,358 candidates change**: 11 plugin `prepare: (untyped) -> nil` methods (through `_FactStore#publish`) and 2 others, from `skipped` / `untyped-return` to `new_method` | identical |
| `lens --format=json` over `lib` (607 files) | identical | identical |
| `lens --format=json` over the plugin trees (201 files) | **15 sites change**: `body_return` goes from `untyped` / `dynamic` to `nil` (12), `Array[String]`, `Array[untyped]` and one tuple array | identical |

Both changes are correct readings, and ADR-130 WD5 treats the two commands differently:

- **sig-gen runs with dispatch off.** A plugin's `prepare` returns `nil` because `publish` declares `-> nil`.
  With dispatch on, sig-gen would write that reading into generated RBS, from an interface the plugin author
  never wrote against. sig-gen reads no analysis cache, so no cache identity is involved.
- **Lens runs with dispatch on, as `check` does.** Lens is documented as the type `rigor check` gives, so the
  15 changed plugin-tree sites are the intended precision, and lens shares `check`'s snapshot.

**A newly reachable finding.** `call.possible-nil-receiver` can now fire in third-party plugin code. It
applies to results of `_Scope#local`, `_Scope#self_type`, `_Scope#source_path` and
`_Environment#nominal_for_name`, which the interfaces declare nilable.

- It is correct by contract, and it is the same finding a `Rigor::Scope` receiver would give.
- The bundled plugin trees measured clean: 0 added rows above.

## Reach (draft 2, `b7e7d73d9`, every interface)

Draft 3 has nothing to reach in the survey targets. Draft 2's counts show where the parity predicate binds
once the facet is general, which is the deferred step.

- The predicate answered `true` for an interface value 3,880 times, at 7 of the 20 sites.
- The other 13 sites were never reached on the corpus, so slice 1b needs a fixture per site.

| Site | Hits |
| --- | ---: |
| `imprecise_argument.rb:28` | 1,586 |
| `imprecise_argument.rb:23` | 1,016 |
| `facet_distribution.rb:122` | 521 |
| `untyped_rejoin.rb:60` | 305 |
| `method_dispatcher.rb:198` | 284 |
| `self_substitute.rb:107` | 93 |
| `statement_evaluator.rb:8742` | 75 |

Draft 1's interface-receiver calls, declared and undeclared:

| Corpus | Declared | Undeclared |
| --- | ---: | ---: |
| `lib` | 16 | 53 |
| plugins | 299 | 4 |
| alba | 37 | 60 |
| mail | 0 | 46 |
| faraday | 0 | 27 |

Every undeclared call inspected exists at runtime.

## Cost

Setup:

- `rigor check --no-cache`, one fresh process per arm, mode `a`.
- `lib` is measured with `tool/engine_alloc_ab.rb` on a frozen corpus.
- Mastodon is measured with its `--measure` child.
- The band is `pr_allocations_pct: 1` (`bench/thresholds.yml`).
- Allocations are deterministic to a few hundred objects. Wall time is noise on this host.

| Engine | Rigor `lib` | Mastodon `app` | Mastodon `lib` |
| --- | --- | --- | --- |
| draft 2, `b7e7d73d9` | +520,176 (+0.70%) | +72,109 (+0.08%) | +10,588 (+0.03%) |
| draft 2 with a `TypeName`-set alias check, `1e5972f66` | +187,301 (+0.25%) | — | — |
| draft 3, `3410399da` | +943,727 (+1.27%) | +142,280 (+0.17%) | +57,089 (+0.19%) |
| **draft 3 with a counting merge, `992d583c6`** | **+5,269 (+0.007%)** | **+4,364 (+0.005%)** | **−2,175 (−0.007%)** |
| round 3, `6037e728a` (nested erasure merge, nil block-pass) | +63,380 (+0.085%) | not re-measured | not re-measured |

Attribution, each step measured as the one change between two arms:

- `TypeName#to_s` in draft 2's core-alias check cost 332,875 allocations on `lib`, 0.45 percentage points
  (`b7e7d73d9` against `1e5972f66`). The review measured 0.42.
- Draft 3 has no core-alias check. The plugin scope compares the `TypeName`'s namespace path, which
  allocates nothing.
- Draft 3's first union merge built a `select` array on every union normalisation. That was +938,458 on
  `lib` (`3410399da` against `992d583c6`), and it is the whole of draft 3's cost above the band.
- Counting before merging removes it.

Round 3 is not attributed. Its nested facet check runs on every union normalisation, and
`HashShape#pairs.each_value.any?` builds an enumerator per shape member; that is the likely source. It
stays inside the band, and the implementation can walk the shape without an enumerator.

The diagnostic count is equal on every arm. The diagnostic, parity, sig-gen and lens measurements ran on
`3410399da`. `992d583c6` changes only how the merge decides, not what it returns, and the fixture
differential on it again removes all 10 review false positives and adds 0.

## First draft: half B (deferred)

Commits `89d12edbb` to `b9011b6ac`. Mechanism:

- The argument rule's and the return rule's declared types translated interfaces bare.
- A thread-local oracle answered `Acceptance`'s `Interface` handler:
  - `yes` when every public member is on the RBS or source surface;
  - `no` when a member is proven absent by the undefined-method receiver-side chain, run without its
    call-site-lexical arms;
  - `maybe` otherwise.

| Corpus | B added | B with the standard union reading (`bu`) |
| --- | ---: | ---: |
| `lib` | 0 | 20 |
| 48 plugin and example trees | 0 | — |
| textbringer | 3 | — |
| alba | 1, then 0 with the root-class rule | — |
| the other eight targets measured then | 0 | — |

Every added row is a false positive:

| Row | Cause |
| --- | --- |
| textbringer `buffer.rb:642`, `rectangle.rb:148:26`, `:148:39` | Wrong project signatures: `save_point: () -> Integer` and `save_excursion: () -> Array[untyped]`. Both methods return their block's value. The base already fires on the same cause at `rectangle.rb:141`. |
| alba `layout.rb:53` | `check_and_return: (...) -> Object` widens `@body`, and its `String` guard sits in another method. |
| `lib` ×16 `File.expand_path(x, __dir__)` (`bu`) | Nullability: `__dir__` is `String?`. |
| `lib` ×2 `result << bytes.byteslice(...)` (`bu`) | Nullability: `byteslice` is `String?`. |
| `lib/rigor/effects/snapshot.rb:287` (`bu`) | Nullability of a project helper's return. |
| `lib/rigor/lens/plugins.rb:28` (`bu`) | `const_source_location`'s pair typed as `Array[String \| Integer]`. |

No true positive was found. The review found that the oracle drops the lexical arms, and that the chain
misses #2792 and #2793. ADR-130 § "Deferred" holds the re-entry conditions.

## Limitations

- In the survey targets draft 3 is inert by construction. Its live evidence is the plugin trees, `lib`
  (`lib/rigor/plugin/base.rb`) and the fixtures.
- No fixture exercised ADR-67 WD3's override of an interface parameter. The predicate routes that branch,
  but nothing here proves it.
- The overload-shape rule's keyword handling is approximate in the prototype: a trailing keyword hash
  against an overload without keywords. Slice 1b needs a fixture per arm.
- The instrument is `interface-proto` at `6037e728a`, local only.
- One base-engine run of the faraday differential crashed with `SIGSEGV`. The rerun was clean, and the
  table reports the rerun.
