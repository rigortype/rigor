# RBS interface types — prototype measurement for ADR-130 (#929)

Status: measurement note, 2026-11-04, engine at `0a53fe62e`. Grounds
[ADR-130](../adr/130-interface-types-value-facet-and-absence-requirement.md); binds nothing.

**Result.** Half A (an interface value is `Dynamic[_Foo]` and dispatch reads the facet) added **no**
diagnostic site anywhere measured: `lib`, 48 plugin and example trees, and twelve survey targets. Half B
(an interface requirement decided by the absence oracle) added **4** across the same set, every one a false
positive caused upstream of the interface check (a wrong project signature, 3; an over-wide declared
return, 1, closed by treating a root-class value as `maybe`, so **3** at the proposed default). The
standard union reading for B added **20** on `lib` alone, all false positives. No true positive surfaced
on the corpus; the fixtures below show the mechanism firing where it should.

## Method

- **Prototype.** Four local commits on `0a53fe62e` (branch `interface-proto` in the
  `interface-assignability` worktree, not pushed; final head `b9011b6ac`). An environment variable picks the
  half:
  - `RIGOR_PROTO_IFACE=a` — half A only. `RbsTypeTranslator` maps `RBS::Types::Interface` to
    `Dynamic[Type::Interface[name, args]]`; `RbsDispatch#receiver_descriptor` maps the facet to
    `[name, :interface, args]`, `lookup_method` answers from `RbsLoader#interface_definition`,
    `build_type_vars` binds the interface's own type parameters, and `self` is the receiver.
  - `RIGOR_PROTO_IFACE=b` — half B only. The argument rule's `translate_param_type` and the return rule's
    declared type translate interfaces bare under a thread-local flag; `Acceptance`'s `Interface` handler
    asks a thread-local oracle the rule installs. The oracle is ADR-130 WD3's: every public member on the
    value's RBS or source surface → `yes`; some member provably absent by `call.undefined-method`'s
    receiver-side chain without its call-site-lexical arms → `no`; otherwise `maybe`. The multi-overload
    channel's name-only `interface_accepts_arg?` asks the oracle instead. Union values use the
    every-member reading. `bu` switches to the standard union reading; a root-class value (`Object`,
    `BasicObject`) is `maybe` from `b9011b6ac` on.
- **Differential.** `tool/engine_diag_diff.rb --base 0a53fe62e --head <proto>`, each arm a fresh process,
  `--no-cache`. `lib` and the plugin and example trees with `--corpus 0a53fe62e`; survey targets with
  `--corpus-dir` on private `rsync` copies (no `.git`, `node_modules` or cache).
  **Every survey baseline was renamed away.** A baseline is count-keyed per file and rule, so one new firing
  in a file releases every baselined firing of that rule there: the first textbringer run read 7 "added"
  rows, 4 of them baseline spill.
- **Plugins.** `plugins/*/lib examples/*/lib` (48 trees) from the repository root, so `sig/` loads. #2681
  already carries `base.rbs` types into hook blocks, so no stand-in was needed. A probe plugin confirmed it:
  under `a`, a `dynamic_return` block's `scope` reads `Dynamic[Rigor::Plugin::_Scope]`,
  `scope.type_of(node)` the 21-member `Rigor::Type::t` union, and `scope.environment`
  `Dynamic[Rigor::Plugin::_Environment]`; all three read `Dynamic[top]` on the base. An undeclared
  `scope.not_in_interface` reports nothing.
- **Reach.** A counter under `RIGOR_PROTO_REACH` (mode `ab`, `--workers=0`): interface-receiver dispatches,
  declared (hit) or not (miss); argument-rule sites whose RBS parameter holds an interface after alias
  expansion; the oracle's per-member verdicts.
- **Cost.** `tool/engine_alloc_ab.rb` on `lib`, and its `--measure` child on Mastodon `app` and `lib`.
- **Positive controls.** A fixture (`tmp/p1`, `tmp/p3` in the worktree) fires under `b` on
  `take(NotImpl.new)` against `_Greeter`, `str(1)` against `_ToStr`, `w(Object.new)` against `_Writer`,
  `e(1)` against `_Each[Integer]` and `s(:sym)` against `string`, and stays silent on a conforming class,
  on a source-only class with a missing member, on `__dir__` against `string`, and on `Array[String]`
  against `_Each[Integer]`. Through `engine_diag_diff` the same fixture reads 3 added rows, so the
  differential can say yes. `bu` on `lib` (20 added) is the control for the corpus runs.

Survey set: textbringer, rgl, kramdown, alba, mail, liquid, faraday, mangrove, haml, herb, rails,
mastodon. Every one ships a `sig/`.

## Diagnostic delta

Rows are `[path, line, column, rule, message]`; "added" and "removed" are head minus base.

| Corpus | Base rows | A added / removed | B added / removed | B (`bu`) added |
| --- | ---: | --- | --- | ---: |
| `lib` | 1 | 0 / 0 | 0 / 0 | 20 |
| plugins + examples (48 trees) | 1 | 0 / 0 | 0 / 0 | — |
| textbringer | 86 | 0 / 0 | 3 / 0 | — |
| rgl | 17 | 0 / 0 | 0 / 0 | — |
| kramdown | 7 | 0 / 0 | 0 / 0 | — |
| alba | 0 | 0 / 0 | 1 / 0, then 0 with the root-class rule | — |
| mail | 22 | 0 / 0 | 0 / 0 | — |
| liquid | 45 | 0 / 0 | 0 / 0 | — |
| faraday | 3 | 0 / 0 | 0 / 0 | — |
| mangrove | 2 | 0 / 0 | 0 / 0 | — |
| haml | 14 | 0 / 0 | 0 / 0 | — |
| herb | 21 | 0 / 0 | 0 / 0 | — |
| rails | 84 | 0 / 0 | 0 / 0 | — |
| mastodon | 2967 | 2 / 2 (text only) | 0 / 0 | — |

Mastodon's runs each also list 4 `rbs.coverage.plugin-signature-stood-down` rows as both removed and
added; they name the per-arm scratch path and are the same rows. Its two half-A rows are one finding each
whose message changed: `app/lib/request.rb:323` and `:326` report `got Dynamic[_ToInt] | Integer` where
the base reports `got Dynamic[top] | Integer`.

Rails is vacuous for this question: its environment fails to build 1,610 class definitions
(`RBS::GenericParameterMismatchError` on `::Array`), so every call reads `Dynamic[top]` and the reach
counter recorded nothing.

## Adjudication

| Row | Half | Verdict | Cause |
| --- | --- | --- | --- |
| textbringer `lib/textbringer/buffer.rb:642` `"\n" + indentation`, `got Integer` | B | FP | Wrong project signature: `sig/lib/textbringer/buffer.rbs` declares `save_point: () -> Integer`, but the method returns its block's value (a String here). |
| textbringer `lib/textbringer/commands/rectangle.rb:148:26` `" " * (start_col - col)`, `got Array` | B | FP | Wrong project signature: `save_excursion: () -> Array[untyped]`, which returns its block's value (an Integer). The base already fires on the same cause at `:141`. |
| textbringer `rectangle.rb:148:39` `start_col - col` against `Array#-`, `got 0 \| Integer` | B | FP | The same signature, read as the receiver. |
| alba `lib/alba/layout.rb:53` `File.read(@body)`, `got Object` | B | FP | `check_and_return: (...) -> Object` widens `@body`; the caller guards `@body.is_a?(String)` in another method. Closed by the root-class rule. |
| `lib` × 16 `File.expand_path(x, __dir__)`, `got non-empty-string?` (`bu` only) | B | FP | Nullability: `__dir__` is `String?` in RBS and never `nil` in a file. |
| `lib` × 2 `result << bytes.byteslice(...)`, `got String?` (`bu`) | B | FP | Nullability: `byteslice` is `String?`; the offsets are in range. |
| `lib/rigor/effects/snapshot.rb:287` `File.fnmatch?(glob, relative, ...)`, `got String?` (`bu`) | B | FP | Nullability of a project helper's declared return. |
| `lib/rigor/lens/plugins.rb:28` `File.expand_path(file)`, `got Dynamic[top] \| Integer \| String` (`bu`) | B | FP | `const_source_location`'s `[String, Integer]` pair typed as an `Array[String \| Integer]` element. |

Per cause, at the proposed default (`b` with the root-class rule): wrong project signature 3; total 3.
Under `bu`: nullability over-declared upstream 19, element-type width 1. Each cause is upstream of the
interface check: the nominal channel already fires on the same shapes when the parameter is a class
(`(String)` against `__dir__` reports today), which is why ADR-130 keeps B opt-in and the union reading
narrow.

## Reach

`ab` mode, one process per corpus. "Sites" are positional arguments the argument rule checks against a
parameter whose RBS type holds an interface; the oracle counts are per interface member of such a
parameter, so a `no` on one arm of `String | _ToStr` is not a firing.

| Corpus | Interface-receiver calls (declared / not) | Sites | of which static arg (single / multi overload) | Oracle yes / no / maybe |
| --- | --- | ---: | --- | --- |
| `lib` | 16 / 53 | 2,999 | 1,368 / 398 | 1,276 / 494 / 0 |
| plugins + examples | 299 / 4 | 484 | 264 / 82 | 305 / 9 / 0 |
| textbringer | 0 / 0 | 514 | 255 / 108 | 275 / 96 / 0 |
| rgl | 0 / 0 | 59 | 25 / 9 | 35 / 0 / 0 |
| kramdown | 0 / 2 | 260 | 138 / 47 | 148 / 16 / 0 |
| alba | 37 / 60 | 25 | 18 / 5 | 15 / 7 / 1 |
| mail | 0 / 46 | 404 | 115 / 160 | 130 / 15 / 0 |
| liquid | 0 / 0 | 134 | 58 / 38 | 51 / 16 / 0 |
| faraday | 0 / 27 | 61 | 25 / 8 | 24 / 7 / 0 |
| mangrove | 0 / 0 | 5 | 2 / 2 | 2 / 0 / 0 |
| haml | 0 / 0 | 81 | 45 / 13 | 48 / 5 / 0 |
| herb | 1 / 0 | 1,214 | 792 / 233 | 797 / 212 / 0 |
| rails | — | — | — | — (vacuous, above) |
| mastodon | 0 / 0 | 1,193 | 730 / 68 | 716 / 48 / 0 |

What the undeclared interface-receiver calls were, on `lib` (53): `_ToPath#to_s` 42, `_ToPath#is_a?` 4,
`_Services#io_boundary_for` 3, and one each of `_Environment#class_ordering`, `_Environment#nil?`,
`_Scope#respond_to?` and `_Services#cache_store`. Every one exists at runtime: an `Object` method, or an
engine member `lib/rigor/plugin/base.rb` reads past the interface (ADR-128 WD6). On the plugins: `nil?` 4.
None would be a correct `call.undefined-method`.

## Cost

`rigor check --no-cache`, one fresh process per arm, prototype head `b9011b6ac` (which also carries the
reach counters, inert without their variable). Allocations are deterministic to a few hundred objects;
wall is noise on this host. The band is `pr_allocations_pct: 1` (`bench/thresholds.yml`).

| Corpus | Base allocations | `a` | `ab` |
| --- | ---: | --- | --- |
| Rigor `lib` (`engine_alloc_ab.rb`, frozen corpus) | 74,402,287 | +276,922 (+0.37%) | +501,744 (+0.67%) |
| Mastodon `app` | 85,485,556 | +68,365 (+0.08%) | +149,735 (+0.18%) |
| Mastodon `lib` | 30,809,219 | +7,011 (+0.02%) | +54,462 (+0.18%) |

The diagnostic count is equal on every arm (Mastodon `app` 2,868, `lib` 393). `lib`'s half-A share is the
interface dispatches and the `Dynamic[Interface]` values replacing the shared `Dynamic[top]`; half B's is
the oracle, which runs one `interface_definition` lookup and a member probe per interface arm of a checked
parameter. Neither is memoised in the prototype.

## Limitations

- The oracle skips the undefined-method rule's call-site-lexical arms (refinements in effect, a singleton
  `def` on the local, the `self.class` mixin form) and answers `maybe` for every class object; the design
  keeps the refinement arm (ADR-130 WD3).
- Overload selection and ADR-35's override rules were not changed, so no inferred type moved under B.
- Intersections of interfaces were not given a carrier (`_A & _B` reads `Dynamic[top]`).
- Nine of twelve survey targets have no interface-typed values in reach at all; half A's evidence is
  `lib`, the plugins and alba.
- The instrument is the `interface-proto` branch named above; it is local to the worktree and will be
  pushed as its own branch if a follow-up needs it.
