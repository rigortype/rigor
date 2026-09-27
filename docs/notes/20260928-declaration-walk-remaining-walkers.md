# The remaining declaration-walk ports paused, and the contract explored for four of them (2026-09-28)

Status: a decision record for #1197. On 2026-09-28, acting on the maintainer's delegation, the coordinator
paused every remaining port to ADR-116 WD5's declaration walk. A traversal contract for four of those
walkers was drafted as an ADR in #1531, reviewed adversarially, and not adopted. The unmerged branch
`walk-statement-sequences-prototype` holds:

- the prototype: commit `9109564fa` adds the statement-sequence events, and `03ba9382d` makes the live
  collectors a bitmask;
- the full draft, verbatim, at `docs/notes/draft-adr-declaration-walk-traversal-contract.md` (commit
  `bf05d5aec`), with the detail the summary below leaves out: `header_parts` for deferred ranges and
  declared names, the `refine` arm, and its answers to the #1527 review's concerns 1, 3 and 4.

The measurements were taken at master `1d05a2c75` (the merge of #1527).

## The decision

Every remaining WD5 port is paused. That is the four this note studies (includes + prepends, extends,
method visibilities, and singleton def nodes) and the other walks the two production sites still run
beside the shared run: the methods/def-nodes walk, deferred ranges, the constant census and declared
names. Deferred ranges carries H2's problem below, and the methods walker needs a `refine` arm. The
draft's bitmask refactor (draft WD5, `03ba9382d`) is paused too: see § The prototype.

- **The four are worth about 0.2% of a cold run.** A null warm run replays the run cache and never reaches
  any of these walks (§ Cost and benefit).
- **#1507's warm-journey profiles put the one-file edit's cost elsewhere.** A Mastodon edit takes 21 s on a
  default `check` and 2.2–16 s on `--incremental`. Most of that is:
  - re-analysis;
  - the run cache, which is all or nothing;
  - snapshot I/O;
  - how wide the dependency closure is.
- **Resuming any of them requires the amendment WD5's rule already demands, justified on C2** (one
  implementation of the context rules) rather than on speed. The open problems at the end of this note
  come first.

## The walkers and where they run

Both production sites build all four tables on every file: a file's own index
(`ScopeIndexer#merge_project_method_indexes`) and the project pre-pass (`#accumulate_project_index`,
through `fold_file_mixin_tables` and `merge_class_keyed_index_tables`).

| Table | Legacy walker | Descends into `def` bodies |
| --- | --- | --- |
| includes + prepends | `walk_class_includes` (`mixin_tables`) | yes (#1521 item 10) |
| extends | `walk_class_extends` (`build_discovered_extends`) | yes |
| method visibilities | `walk_method_visibilities` | no |
| singleton def nodes | `walk_singleton_def_nodes` | no |

## What each needs that the walk does not express

This section was read from the walkers at `1d05a2c75`. It is not validated: the corpus sweeps below cover
only the three ported collectors and a visibility sketch. Its framing is disputed, and its list of quirks
is incomplete: see H1 and H2 under § Open problems.

- **Sibling-order state** *(disputed, H2: `module_function` decides the definee, which is context)*.
  - Visibilities. The default visibility flows left to right through every statement list, not only through
    class bodies. A bare `private` counts only as a statement of its own, so `foo(private)` changes nothing. A
    nested list (`if` branches, blocks, parentheses) starts from the enclosing list's current default and
    hands nothing back. A class, module, `class <<`, meta-new or eval body starts at `:public`, and so does
    each clause list of a body-level `begin`.
  - Singleton defs. A bare `module_function` flips every later `def` in the same body. Its scope is the
    body's direct statements, flattened across a body-level `begin`'s clauses (`statements_of`). A `def`
    nested in an `if` ignores it. `module_function :a, :b` looks at the whole body.
- **The definee**, which is where a receiverless `def` installs. It is not `self`.
  - `class << Foo` opens `Foo`'s singleton (`singleton_class_prefix`), where the walk answers an unnamed self
    (#1521 item 6).
  - Extends keeps the owner only for `class << self` outside a singleton body.
  - `instance_eval` / `instance_exec` put a `def` on the singleton side while `include` and `private` stay
    on the receiver (`eval_body_def_context`).
- **`define_method`.** Includes treats its block as opaque (`rebound_block_self`), and extends walks it
  ownerless. Every other walker walks it as an ordinary call.
- **Traversal quirks** *(incomplete, H1)*.
  - Extends skips `END { }`, and skips every other block-carrying call entirely (#1521 item 12).
  - Includes keeps an eval receiver as written (#1521 item 9).
  - Includes, extends and visibilities walk block parameters under the rebound owner.
  - Visibilities and singleton defs walk a bare factory block as an ordinary call (#1521 item 8).
  - The review found more of these (see H1 under § Open problems).

## Cost and benefit

**Method.** The figures are in-process CPU seconds (the process CPU clock). Each is the best of 11 passes
over the same parsed trees, with the arms alternating, on one development host: Apple M4 Pro, macOS 26.7,
Ruby 4.0.5. The master arm read anywhere from 0.066 s to 0.072 s across processes. That spread is the size
of the single-digit percentages below, which therefore do not resolve. `lib` is 530 files and Mastodon
`app` 1,154.

What the four legacy walkers cost, each walked alone, with YJIT on:

| Walker | `lib` | Mastodon `app` |
| --- | ---: | ---: |
| includes + prepends | 0.025 s | 0.013 s |
| extends | 0.022 s | 0.010 s |
| visibilities | 0.005 s | 0.004 s |
| singleton defs | 0.004 s | 0.003 s |

What a port would save, as an upper bound, because a collector still builds its own table:

- **Visibilities and singleton defs: nothing.** Both stop at `def`, so they walk only the declaration
  spine. A visibility sketch collector in the shared run cost, dispatch and table together:
  - about 0.0047 s against 0.005 s on `lib`;
  - about 0.0042 s against 0.004 s on Mastodon, where it is slower.
- **Includes and extends: up to about 0.047 s** per site over `lib`. With both production sites that is
  about 0.09 s per cold run.
- **Against a whole run.** `bench/baseline.json` has a cold `rigor check lib` at about 46 s wall on CI, so
  the two ports are worth roughly 0.2%. The hosts differ, so the ratio is only indicative.

The prototype's bitmask traversal on its own saved 0.006 s on `lib` with YJIT on and nothing with YJIT off.
It allocated 4.5 fewer objects per file: about 4,800 for a cold `lib` run, which is 0.01% of its 38.5M
allocations.

## A contract explored and not adopted (2026-09-28)

### The proposal, in brief

The draft ADR (#1531) applied one criterion. The walk computes what the context is at a node, once for
every collector. A collector owns what its table accumulates, including sibling-order state. Handlers answer
only `DESCEND` or `DECLINE`, and an event reaches a collector only where it is still live.

- **Draft WD1 — statement-sequence events.** `on_sequence(node, context, body)`, then `on_statement(node,
  context)` for each direct statement, then `on_sequence_end(node, context)`. The collector keeps its own
  stack.
- **Draft WD2 — the definee in the context.** Both the definee and the class whose singleton `self` is,
  set by the transitions. Extends names a `:self_first_level` variant.
- **Draft WD3 — a `define_method` block arm, as a rule with variants.** It was chosen over a "descend with
  `self` rebound" answer.
- **Draft WD4 — rules with variants for the quirks:** `post_execution`, `eval_receiver`,
  `rebound_block_parameters` and `header_parts`.
- **Draft WD5 — the live collectors as a bitmask.** Nesting tracking was to be enforced by a `ContractError`.
- **Draft WD6 — port order:** draft WD5 alone, then includes, extends, visibilities and singleton defs.

The alternatives it rejected:

- a general exit event;
- a `class <<` event;
- the rebind answer;
- a fold threaded by the walk;
- per-subset event gating over Arrays.

### The prototype

- **Statement-sequence events.** `spec/rigor/inference/declaration_walk_sequences_spec.rb` pins:
  - the event order and the `body` argument;
  - a decline;
  - byte-identical shared tables with a sequence collector in the run;
  - no allocation per statement.

  A body-level `begin` is walked by hand in `rigor_each_child` order, so the rest of the run sees the
  events it saw before.
- **The live collectors as a bitmask.** `Traversal#walk(node, run, live, context)` carries an Integer over
  the run's positions.
  - Only the live collectors that take an event are asked.
  - A decline clears a bit, and a variant fork is a mask intersection. Neither allocates.
  - The traversal holds classes and masks, so the main Ractor caches one per run shape.
- **Byte-identity.** The three existing collectors' tables matched the legacy walkers under the strict
  comparer. That covered 67,137 files (this repo, `tmp/corpus` and eight survey checkouts including
  gitlab) and 12,000 fuzzed programs. The fuzzer's positive control still fired for every variant.

**The bitmask refactor is paused too.** It was the draft's first step, and it must not land alone as a
free speedup. It saves 0.006 s on `lib` with YJIT on and nothing with YJIT off (below). It also carries
two of the review's open problems: M1 (it raises `ArgumentError`, not a `ContractError`) and M2 (its
traversal cache serves only the main Ractor).

The production shared run, master against the bitmask. These are single processes: the master arm read
0.066–0.072 s over `lib` across processes, a spread as large as the differences below.

| Target | YJIT | master | prototype | objects / file |
| --- | --- | ---: | ---: | --- |
| `lib` | on | 0.071–0.072 s | 0.064–0.066 s | 63.4 → 58.9 |
| Mastodon `app` | on | 0.038–0.040 s | 0.032–0.033 s | 35.2 → 31.3 |
| `lib` | off | 0.185 s | 0.186 s | 63.4 → 58.9 |
| Mastodon `app` | off | 0.106 s | 0.100 s | 35.2 → 31.3 |

What a fourth collector added to the bitmask run, with YJIT on. The same spread applies, so percentages
below about 10% do not resolve:

| Fourth collector | `lib` | Mastodon `app` |
| --- | ---: | ---: |
| declines at `def` | +0.6% | +0.8% |
| … and takes calls | +1.0% | +1.2% |
| … and takes sequences | +4.2% | +7.6% |
| … and takes both | +4.4% | +8.2% |
| takes calls everywhere | +2.8% | +3.3% |
| the visibility sketch (dispatch and its table) | +7.3% | +12.6% |

What the bitmask fixed. Before it, the sequence events cost a spine-only collector about +20% on `lib`, but
the sequence path itself ran only 2,551 times over 378,292 nodes. The cost was gating events per run: every
node inside the `def` bodies the collector had declined still dispatched. Gating per subset over Arrays
still left +18%, from 108,034 hash lookups. At about 175 ns a node, any per-node Ruby-level check shows.

### Open problems a revival must solve first

The adversarial review of #1531 found these.

- **S1 — draft WD3's variants are not decided by the corpus.** Draft WD3 let the shadow sweep decide
  which collectors name `:ordinary_call`. But by #1521 item 9, every existing collector walks a
  `define_method` block as an ordinary call, and so do both sequence walkers. So all of them must name `:ordinary_call` by
  construction. A corpus without the construct passes the sweep without checking anything.
  `class C; define_method(:x) { class self::E < S; end }; end` records `C::E => "S"` in the legacy
  superclass table, and `:instance_self` drops it with no corpus diff. Draft WD3 also left open whether a
  `define_method` body sets `class_body`, which moves `anonymous_class_path` keys.
- **H1 — the quirk list was incomplete, and draft WD2–WD4 are unvalidated reads.**
  - `walk_singleton_meta_new?` walks only `meta_new_block_body`, never the factory's receiver or
    arguments. A port would add `X.m` for `K = Class.new(X.class_eval { def self.m; end; X }) {}`.
  - An eval block whose body is a `BeginNode` skips `walk_singleton_body`.
    `X.class_eval do module_function; def f; end; rescue; end` records `X.f` under a port and not under
    the legacy walker. `Context` cannot tell that body from a class body's `begin`.
  - Includes and extends anchor `self::` on an unsplit `[owner]`.
  - Extends stops at an unrendered header (#1521 item 3).
- **H2 — the criterion contradicts draft WD1.** `module_function` decides where a `def` installs, which is
  the definee, and by the criterion that is context. Three walkers compute it in three ways:
  - `walk_singleton_body` (~L4949) flips a toggle at a bare `module_function` among a body's direct
    statements, flattened across a body-level `begin`.
  - Deferred ranges' `walk_deferred_body` (~L4192) prescans the body with `collect_module_function_state`
    for bare-call offsets. It enters blocks and control flow, but not nested declarations, `def`s, `END`
    or eval blocks. It also tracks the `defs_singleton` definee.
  - Extends' `record_extend_call` (~L6186) records a bare `module_function` as the module extending
    itself, with no order at all.

  The missing alternative is a shared context value, rebuilt only at a bare modifier statement.
- **H3 — the benefit was overstated.** The draft compared about 0.009 s of dispatch with the legacy walks'
  full 0.056 s. § Cost and benefit has the corrected comparison.
- **M1 — draft WD5's nesting `ContractError` was underspecified.**
  - It did not say where a variant declares that it needs a tracked root.
  - `Context#nesting` is nil for a lost chain too.
  - `SuperclassesCollector` and `DefNestingsCollector` read `context.nesting` directly.
  - The prototype's `MAX_COLLECTORS` raises `ArgumentError`, not a `ContractError`.
- **M2 — the traversal cache serves only the main Ractor.** Traversals hold only Integers, so precomputed
  shareable ones could serve every Ractor. Each spec's `Class.new(recorder_class)` also pins an entry.
- **M3 — draft WD2 misgrouped and over-eager.**
  - It grouped `singleton_cref` with the `self`-side fields, but it belongs to the lexical cref.
  - Building the value on every transition allocates per body and resolves the definee eagerly.
  - `:self_first_level` must key on the "self is a singleton" field, not on `singleton_cref`. Legacy extends
    records `X` for `class << self; X.class_eval { class << self; include M; end }; end`.
- **Scope.** "The remaining walkers" overclaimed. The methods/def-nodes, deferred-ranges, constant-census
  and declared-names walks also still run separately.
