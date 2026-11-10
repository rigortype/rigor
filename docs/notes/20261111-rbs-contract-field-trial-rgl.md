# `rigor-rbs-contract` field trial: a new RBS entry for rgl 0.6.7

Status: field report, 2026-11-11. One agent run (Claude Opus 5.5) followed the skill as merged in #3061
(ADR-131) to draft a new gem_rbs_collection entry for rgl 0.6.7, a pure-Ruby, YARD-documented gem
with no RBS upstream and no collection entry. Nothing was pushed or filed by the run. The skill changes
this note motivates land with it; the Rigor gaps are filed as issues.

## Setup

- Target: a copy of `monora/rgl` at `d01746e` (0.6.7), scope about half the gem: graph core,
  mutable/adjacency graphs, edges, traversal and visitors, `ImplicitGraph`, topsort, `path?`,
  connected components, Dijkstra.
- Rigor master `a74be9197` through the Flake; rbs 4.2.0 and steep 2.1.0 from a separate Ruby 4.0.6 for
  the runtime and Steep work.
- `bin/test` was not run (it needs the network); its three checks were run offline.
- About two hours of agent time.

## Result

A draft of about 124 declarations in five files plus `_test/test.rb`. `rbs validate`, `steep check` (0
errors), `steep stats` (0 untyped calls), `rigor check --no-baseline` on `lib/` and `_test/` (0) and
`sig-gen --diff` (no `tighter_return`) all passed. It cannot go upstream as is: rgl's iterators
`include Stream`, and the `stream` gem has no entry.

| | count |
| --- | ---: |
| `sig-gen` candidates in scope | 126 (52 proposals, 74 skipped) |
| proposals adopted as printed | ~25 |
| proposals whose return was replaced by `void` / `bool` / `instance` by judgement | 13 |
| proposals made more precise from the documentation | 4 |
| skipped methods filled from the documentation | ~22 |
| methods `sig-gen` never saw (`class_eval`-generated) | 14 |
| declarations changed on a runtime witness alone | 0 |

The static signals located candidates and decided none. The documentation sweep and the runtime
witnesses decided everything: witnesses refuted two YARD `@return` tags (`Graph#reverse`,
`#to_undirected`) and a README example (`remove_edge … #=> true`; it returns a `Set`), and confirmed a
documented `nil` (Dijkstra on an unreachable target).

## What the trial taught

1. **The runtime checker has a silent blind spot, so a witness needs its negative control.** It
   checks a method only against a declaration on the class or module that defines it, so a declaration
   inherited from a module or superclass by a class that overrides the method is skipped: `remove_edge`
   declared `-> bool` on `MutableGraph` and overridden in `DirectedAdjacencyGraph` returned a `Set` and
   the run exited 0. rgl's suite (77 tests, one expected failure) ran under `rbs/test/setup` while every
   such declaration went unchecked. A declaration-mutation pass (break each return in turn, re-run,
   list what no run notices) found them mechanically: on the draft, 61 mutants, 56 killed, 5 survived —
   three of them this skip rule (`Graph#directed?`, `#has_vertex?`, `#has_edge?`), `Graph#to_s` never
   called, and the `?` on `Edge::DirectedEdge#<=>` with no witness. The first versions of the pass
   miscounted (whole error lines compared, so value noise read as kills; `[]` methods and calls
   through an alias missed); review of #3073 caught them. ADR-131 WD7.
2. **A new entry is the commonest collection contribution, and the skill had no path for it.** The
   loop was audit-shaped. "Adopt a `new_method` proposal verbatim" would have shipped `set_source -> 0`,
   `reset -> {}`, `find_shortest_paths -> nil`, `Graph#directed? -> false` (a default subclasses
   override with `true`) and `set_to_begin -> Hash` as contracts. The `void` rule that forbids this was
   written only for existing declarations.
3. **`sig-gen` writes types, not a skeleton.** No `include`, `attr_*`, `alias`, constants or
   metaprogrammed methods, so `Graph` lost `Enumerable`. `rbs prototype runtime -r FEATURE` supplied the
   skeleton; its flags were found by trial (`-R` is `require_relative`, there is no `-I`), and rbs 4.2
   marks it deprecated.
4. **Documentation disagrees with itself.** `Graph#reverse` is tagged `@return [DirectedAdjacencyGraph]`
   while its prose says an undirected graph returns `self`; `sig-gen`'s union was right. A witness
   settled it. The skill now says the gem's YARD tags are documentation to grade, not an oracle, and that
   a witness decides conflicts.
5. **The rest was environment.** `bin/test` assumes the network; the witness line assumed `rbs` was in
   the target's bundle, and exporting `GEM_PATH` for the witness broke Steep's gem resolution; a
   dependency with no entry (`stream`) had no route; blocks and a documented contract that crashes
   (`depth_first_search` without a block raises `NoMethodError`) had no rule.

What worked as written: the early-return warning predicted exactly which wrong declarations
`def.return-type-mismatch` would miss; the memoised-value triage row transferred directly to
`GraphVisitor#color_map`; "never resolve an open question by the option the body matches" stopped a
`remove_edge -> Set` contract; the witness recipe worked first time once the Ruby was right.

## Rigor gaps found

| Gap | Issue |
| --- | --- |
| A local rebound in a block passed to a non-folded callee reads `Dynamic[top]` after the call, so counter-style methods are skipped | #3066 |
| `sig-gen` drops the optional block of a `yield … if block_given?` method | #3067 |
| `sig-gen` silently omits an `initialize` that yields `self` when `block_given?` | #3068 |
| `sig-gen` renders `new` in a singleton method and `self.class.new` as the lexical class, not `instance` | #3069 |
| `def.return-type-mismatch` on a memoised ivar re-read after `yield` (found in the ADR-131 design review, filed with these) | #3070 |
| early returns invisible to `def.return-type-mismatch`, reconfirmed on `Graph#reverse` | #3062 |

`sig-gen` emitting no `include` / `attr` / `alias` / constants may be by design; the skill now says so.

## Not covered

Bellman-Ford, bidirectional, bipartite, DOT, Edmonds-Karp, GraphXML, Prim, transitivity and
condensation were left undeclared. The `stream` stub the draft relies on was not reviewed as an entry.
