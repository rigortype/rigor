# ADR-132 — One reflective-call view for every analysis

Status: **Proposed, 2026-11-12.** Nothing has landed. The first slice (S0: the seam, its unit spec, the
spelling matrix and the source ratchet at today's counts) changes no behaviour. Archetype: deliberative.
Stakes: high — the seam is engine-wide and every behaviour slice moves diagnostics on correct code, though
each slice is reversible on its own.

Grounding: [`docs/notes/20261112-reflective-call-inventory.md`](../notes/20261112-reflective-call-inventory.md)
(the 36-site inventory, a 14-project frequency survey, and the corrections two independent design consults
made to it).

## Context

Ruby reaches a method by name in more than one way: `send` / `__send__` / `public_send`, a `method(:m)` or
`instance_method(:m)` handle that is then called, and the block-pass `&:m`. Rigor has no shared reading of
these. Thirty-six sites in `lib/` recognise the `send` family themselves, through twenty-six separate
constants equal to `%i[send __send__ public_send]`. They include the censuses, the mutation floors,
`$~` / `$_` rebinding, return barriers, visibility and `module_function` state, `ScopeIndexer`'s definer
walkers, effects, reachability, sig-gen, check rules and the typer's literal-send shortcut. About sixteen
files classify `&:sym` independently, and one rule models method-handle chains.

The sites disagree on the same spelling, and the disagreement is not in the name list:

- **Extraction.** `send("push")` is a call of `push` for about 28 sites and not for the rest, which read
  only a `SymbolNode`. Only one site reads the literal fragments of `send("#{m}_x")`.
- **The argument shift.** Thirteen sites drop the selector argument by hand. The typer drops it from the
  argument types but passes the outer node to dispatch, whose tiers then read the outer argument list, so `send(:Integer, "1", exception: false)`
  types `Integer` where the direct call types `Integer?` (#1872).
- **Policy for a computed name.** Seven sites give seven answers: taint, `reached!`, `any_entry`, open
  world, "does not clear", `nil`, decline.
- **Missed spellings.** `send(:define_method) { }` is counted by the ivar census and not narrowed by the
  block-self rule, so the two disagree about the same block (#2167).

Every fix lands in one consumer, and the next review finds the same spelling missing in another. The goal
is that a spelling is learned once and every consumer sees it the same way, while each consumer still
decides for itself what an unknown name means.

The payoff is consistency and review cost, not precision. Reflective spellings are rare: across the 49
survey checkouts the `send` family is 0.130% of 7.65M call nodes, metaprogramming selectors reached
through `send` are 0.003%, and 36% of sends have no literal name. Of the 27 issues the inventory maps to these sites, the view
closes three outright (#1872, #2167, #2704), removes one item from about eleven, and does not touch about
twelve (receiver resolution, closures, eval semantics). This ADR does not promise the last group.

Two findings bear on the design:

- `try_literal_send` assumes every `send` is `Kernel#send`. `Mailer.new.send(:hello, 0).even?`, with
  `Mailer#send(message, flags)` defined, reports `call.undefined-method` for `"0"`; Ruby prints `false`.
  Only the SymbolNode-only extraction keeps `sock.send("payload", 0)` out of the same trap, so widening the
  typer to String names is unsafe on its own. The same assumption reaches syntactic consumers:
  `ReturnBarrier.block_call?` reads `send(:lambda) { return nil }` as a lambda on any receiver, so in a
  class whose own `send` yields, a method that returns `nil` types `Integer`. Over-approximating a call is
  safe only for a consumer whose answer widens.
- Node identity is load-bearing. `TypeOfMemo`, `Scope#dynamic_origins` / `void_origins` /
  `plugin_typed_calls`, and `scope_index` (read at 54 sites) are identity-keyed by the call node.
  `AliasMutationFloor.literal_send_target` already synthesises a `CallNode` with `copy`, and
  `StatementEvaluator` (~2083) passes a copy to `type_of`, where it can never hit the memo.

## Decision

Add one syntax-only seam, `Rigor::Source::ReflectiveCall`, and route every reflective-spelling recognition
in `lib/` through it.

**Criterion.** The view canonicalises a spelling exactly when core Ruby defines it as one invocation of one
named method, and the node's own subtree fixes four facts: the method's name (or that no literal fixes it),
the argument and block nodes the target receives, the node that becomes `self` and where lookup starts,
and whether Ruby checks visibility. A wrapper that changes the target's arity or callability (`curry`,
`unbind`) breaks the chain. Anything that needs more than the subtree stays with the consumer:
types, method tables, a local's bindings, parent or sibling nodes, the meaning of a code string, and the
conservative answer for an unknown name.

Applied:

| Spelling | In the view? | Why |
|---|---|---|
| `send` / `__send__` / `public_send`, nested too | yes | all four facts are in the subtree; the name may be exact, a pattern, or computed |
| `r.method(:m).call(a)`, `.()`, `[]`, `===`; `M.instance_method(:m).bind_call(o, a)`, `.bind(o).call(a)` | yes | the handle is in the receiver chain |
| `&:m` | yes | the first value the carrier yields is `self`, the rest are arguments: a role, not a node |
| `&r.method(:m)` | yes | `self` is `r`; every value the carrier yields is an argument |
| `r.method(:m).curry.call(a)`, `.unbind.call` | no | the wrapper changes arity or callability |
| `m = r.method(:x); m.call`, `send(name)` with `name = :x` | no | needs a binding; typed consumers use `Type::BoundMethod`, `ScopeIndexer#local_send_names` stays local |
| `instance_eval { }`, `class_exec { }` | no | a frame rule, not a named invocation (ADR-116 WD5's context, the block-entry model) |
| `eval("...")`, `class_eval "..."` | no | the code is a string |
| `define_method`, `alias_method`, `instance_variable_set`, `const_get` called directly | no | direct calls; through `send` they arrive unwrapped, and the consumer's role check runs on the name |
| ActiveSupport `try(:m)` | no | not core; a plugin owns it (ADR-0) |

### WD1 — The value: original nodes only

```ruby
module Rigor::Source::ReflectiveCall
  Invocation = Data.define(:node, :method_name, :name_node, :argument_offset, :block_node,
                           :self_node, :owner_node, :via, :public_only)

  def invocation(node)         # Invocation | nil — the send family, handle chains, bind_call
  def block_pass(call_node)    # Invocation | nil — call_node.block as `&:m` / `&r.method(:m)`
  def called_name(node)        # Symbol | nil, no allocation — node.name, or the literal target, or nil
  def argument_nodes(inv)      # Array[Prism::node] | nil — nil when the offset is not an Integer
  def may_name?(inv, name)     # false only when the subtree proves the name cannot be `name`
end
```

- `node` is the analysed tree's own node: the outer `send` / `.call` / `bind_call` `CallNode`, or the
  `BlockArgumentNode` for block-pass (what `ExpressionTyper#apply_hash_block` already passes as
  `call_node:`, expression_typer.rb ~6642). It is the only thing a consumer keys on or reports at.
- `method_name` is a Symbol through `SymbolName.of`, which owns the encoding guard, or `nil` when no literal
  fixes it. `nil` means "not known", never "no call". `name_node` is the operand that spells it, for
  DiscoveryIndex rows (built from its location, as `record_definer_name_row` does) and partial reads.
- `argument_offset` says where the target's arguments are:
  - an Integer: they start at that index of `node.arguments.arguments` — 1 per `send` level, 0 for
    `.call`, 1 for `bind_call`;
  - `:yielded_after_self` (`&:m`): the first yielded value is `self`, the rest are the arguments;
  - `:yielded` (`&r.method(:m)`): every yielded value is an argument;
  - `nil`: unknown, because a splat or `...` hides where the selector or the bound receiver ends
    (`a.send(*[:push, x])`, `bind_call(*xs)`). A must-consumer declines; a may-consumer treats every
    argument node as possibly passed.

  `argument_nodes(inv)` returns the tree's own nodes for an Integer offset and nil otherwise, so no
  consumer indexes with a Symbol and `type_of(arg)` keeps hitting the memo.
- `self_node` is a node, `:implicit`, or `:yielded` (only for `&:m`). For `r.method(:m).call` and
  `&r.method(:m)` it is `r`, because the capture happens at `method`. `owner_node` is set only for
  `instance_method` chains: lookup starts at that module's instance side, not at `self`'s class.
- `via` names the governing spelling. `public_only` is true when Ruby raises unless the target is public:
  `public_send`, `public_method`, `public_instance_method`, and `&:m` (a Ruby 4.0.5 probe raises
  `NoMethodError` for `[o].map(&:priv)`). Nested senders unwrap, and the innermost governs:
  `o.send(:public_send, :priv)` raises, `o.public_send(:send, :priv)` returns.

**Code anchors.** The seam lives in `lib/rigor/source/reflective_call.rb`, beside `Source::Literals`,
`SymbolName` and `AliasNames`, and gets a row in `spec/rigor/source/require_hygiene_spec.rb`. Its seeds
are the four partial views that exist today: `ReceiverWriterCall.called` (receiver_writer_call.rb ~55),
`ScopeIndexer#mixin_call_view` (~8405) and `#visibility_call_parts` (~9612), and
`RebindingBlockCallees::Dispatch.dispatch` (dispatch.rb ~28).

**Cost.** On a non-reflective node `invocation` and `called_name` are one frozen-Set lookup on `node.name`,
plus a receiver check for the invoker names. Neither allocates. A reflective node allocates one `Data`.
There is no memo: it would pin trees, add a run-scoped slot (ADR-129), and cost more than the 0.17% it
serves.

### WD2 — Guardrails: what the view must not do

1. **Resolve or type.** The seam file references no `Inference`, `Scope`, `Type`, `Reflection` or
   `Environment` constant (spec-checked). It does not decide that `send` is `Kernel#send`.
2. **Decide conservatism.** A computed name is `method_name: nil`, never "opaque", "any" or "decline".
   A consumer chooses `method_name == :x` (must) or `may_name?(inv, :x)` (may), and that choice is its
   conservatism, written at its own call site.
3. **Mint, copy or store nodes.** Every node-valued field is a node of the tree. An `Invocation` is never
   a Hash key, never stored in DiscoveryIndex, seed bundles, caches or fork payloads, and never
   Marshalled; rows store offsets.
4. **Look like a `CallNode`.** No field shares a name with a `Prism::CallNode` reader. That alone does not
   fail loudly: dispatch tiers guard with `respond_to?` and rescue, so a stray `Invocation` would quietly
   take a "not a call" branch, the #1872 shape again. `CallContext.build` therefore asserts that
   `call_node` is a Prism node (WD3). #1872 was a value that half-corresponded.
5. **Read outside the subtree.** No parent walks, no locals, no code strings, no framework spellings.
6. **Classify selectors.** It does not know that `define_method` defines or that `instance_eval` rebinds.
   The role names live in a separate table (WD4).
7. **Hand out its own spelling sets.** The sender, reader, invoker and binder sets are `private_constant`
   in the seam, so a consumer cannot import `SENDERS` and keep its own extraction; it has to call
   `invocation`.
8. **Change the plugin API.** Plugins keep `call_node` (ADR-2). Exposure waits until the value has
   settled (D4).

### WD3 — Dispatch reads the call through the context, and only a genuine `send` is a reflective call

**Dispatch.** The rule is that a tier reads the call's name, argument nodes, receiver and visibility from
the `MethodDispatcher` call context, never from `call_node`, which stays only as the identity key and the
report location. The context gains `argument_offset` (default 0) and `public_only`, and argument nodes are
read through `ArgumentNodes.for(context)`. The readers that change include `RbsDispatch#splat_indices`
(~1502), `#plain_positional_arguments?` (~1835), `#class_factory_argument?` (~2011, which has no size check
today and reads the selector as an argument), `InterfaceShape` (~119), `KernelDispatch` (~268),
`HashTransformKeysFolding` (~167), `SetFolding` (~108), `DataFolding` and `StructFolding`'s
`keyword_new?`, `ShapeDispatch` (~356), `MatchDataFolding` (~71), `ArgumentNodes.keyword_hash_last?`,
`explicit_non_self_receiver?` (whose outer-node reading makes `o.send(:priv)` public-only today), and the
plugin contribution gate (which sees `:send` and never applies to `x.send(:find, 1)`). A spec forbids
`call_node.arguments`, `.receiver` and `.name` under `method_dispatcher/`, so the list cannot go stale.
`CallContext.build` asserts that `call_node` is a Prism node. `try_literal_send` then dispatches with
`call_node: inv.node`, the offset and `inv.public_only`. The side tables stay keyed by the node the user
wrote, and every tier sees what the direct call would give it. The context stays in its 160-byte slot at
that field count (measured).

**A genuine receiver.** Whether `send` is `Kernel#send`, or `method` is `Kernel#method`, is a fact about
the receiver, so the view cannot know it (WD2.1). Each consumer's answer goes one of two ways when the call
turns out to be an ordinary method named `send`:

- A consumer whose answer **widens** — the censuses, the mutation floors, reachability, the `$~` / `$_`
  taint — loses only precision by reading it as reflective. It needs no check.
- A consumer whose answer **narrows a type or emits a diagnostic** — the typer, constant folding,
  `ReturnBarrier`, effects edges, deprecations, visibility rows — produces a wrong type or a false
  positive. It checks that the receiver's `send` (or, for a handle chain, `method` / `instance_method`)
  resolves to `Kernel` / `BasicObject` with no project or RBS override, and takes the answer that says
  less when it cannot: a syntactic consumer with no types does not treat the call as reflective unless the
  receiver is implicit or `self` and the enclosing class defines no `send`. `__send__` and `public_send`
  are taken as genuine.

The matrix (WD5) records which way each site goes; a narrowing site without the check is a declared
exception naming an issue.

### WD4 — Selector roles are declared once

`Source::ReflectiveCall::Spellings` holds frozen Symbol Sets by role: the view's own (senders, public
senders, handle readers, invokers, binders), which stay private to the seam (WD2.7), and the public roles
consumers check after unwrapping (`BLOCK_EVALUATORS`, `STRING_EVALUATORS`, `DEFINERS`, `SINGLETON_DEFINERS`, `ALIASERS`, `IVAR_WRITERS`,
`CONST_WRITERS`, `VISIBILITY_SETTERS`, …). A consumer that wants a narrower set writes it as an expression
over the roles with its reason beside it. Some differences are legitimate — `MatchRebinding::SelfCalls`
keeps `EVALS = {eval}` because only `eval` shares the caller's `$~` frame — so this is a role table, not
one list, and today's ten unequal eval sets become visible arithmetic. This is ADR-116's C1 ("declare
each kind once") applied to names.

### WD5 — Pin before moving, ratchet after

The corpus holds too few reflective spellings to prove a move preserved behaviour. So two specs land
first, at today's answers:

- **The spelling matrix** (`spec/rigor/inference/reflective_spelling_matrix_spec.rb`). Rows are spellings:
  the three senders × Symbol / String / invalid-encoding String / interpolated / computed / splat names ×
  implicit / `self` / constant / other receivers, nested senders, handle chains, `bind_call`, `&:m`,
  `&r.method(:m)`, and a class that defines its own `send`. Columns are **sites**, one per recognising
  site, not one per consumer family: a family column would let a move change one site's answer while the
  family's fixture observes another. Each cell is "same as the direct call" or a declared exception that
  names an issue or one of the decisions below. A pure slice adds no exception. Paired sites (#2167's
  census and narrowing) assert equal columns.
- **The source ratchet** (`spec/rigor/source/reflective_spelling_ratchet_spec.rb`). A Prism scan of
  `lib/**/*.rb`, outside the seam, counts per file the Symbol and String literals that name a sender,
  handle reader, invoker or binder, and references to `Spellings` role constants, against an exact table
  generated when S0 lands (about 116 sender SymbolNodes today), in the style of
  `spec/docs/plugin_io_boundary_spec.rb`. Unrelated uses (`:bind` as an option key, `:method` as a Hash
  key) are listed by file in the table, with a reason. A count that differs in either direction fails, so
  a slice lowers its row. The same spec allows node minting — `.copy(` and `Prism::*Node.new` — only at
  today's callers.

The ratchet measures where spellings are written, and the matrix measures what each site answers; neither
alone shows that extraction moved onto the view. A site counts as ported only when its ratchet row is zero
and its matrix column has no exception that the view's answer would remove.

Each slice then flips named matrix cells. A slice that changes what `ScopeIndexer` records bumps the
DiscoveryIndex `SCHEMA`, or warm and `--incremental` runs serve the old reading.

### WD6 — Slices

Pure slices are byte-identical on the matrix, `make check` and `make check-plugins`, show an empty
`tool/engine_diag_diff.rb`, and are neutral on `tool/engine_alloc_ab.rb` (ADR-116's guardrail: a
behaviour change never rides in a move). A site's departure from the view survives a pure move as a
counted, labelled quirk at the call site, which a later slice removes. Behaviour slices are one PR each,
with an adjudicated corpus diff.

| # | Slice | Kind | Closes or reduces |
|---|---|---|---|
| S0 | Seam, unit spec, `Spellings`, matrix, ratchet | additive | — |
| S1 | Re-seat the four partial views and `CalleeWriteCensus.literal_send?`; then port the sites whose extraction already equals the view's, one family per PR (censuses; frame globals and flow; `ScopeIndexer`; rules, reachability, sig-gen, effects) | pure | constants 26 → 0 outside the seam |
| S2 | SymbolNode-only sites read String names too (repeated `\|\|=`, `send_extend?`); the narrowing ones (deprecations, return barrier) only with WD3's receiver check; the accidental `public_send` exclusion for `private_class_method` goes | behaviour | divergence 1 outside typing; the `ReturnBarrier` wrong type |
| S3 | WD3: the offset channel, the genuine-`send` check, then String names in the typer | behaviour | #1872, the user-defined `send` false positive |
| S4 | Sites that miss `send`: `DefineMethodBlockSelf` with `Scope#block_self_narrowing_unknown?` and `CensusForeignBlock` in one PR; Lens `visibility_call?`; `LexicalMethodSites` | behaviour | #2167; items of #2160, #2087, #2984 |
| S5 | Computed names, one consumer per PR, starting with the alias floor through `may_name?` | behaviour | #2704; items of #2697, #2376 |
| S6 | Block-pass readers on `block_pass` | behaviour | items of #2913, #1417 |
| S7 | Consumers of role sets move onto WD4 and see these calls through `send` | behaviour | items of #3057, #2983, #1377 |

The seam is done when every site is ported in WD5's sense, the ratchet reads zero outside
`reflective_call.rb` (apart from allowlisted type-level uses such as `ConstantFolding`), every remaining
matrix exception names an open issue or a ratified decision, and a new spelling is one edit in the seam
plus one matrix row.

## Rejected alternatives

| Alternative | Why not |
|---|---|
| Desugar the AST before analysis (a Prism rewrite, or an ADR-17-style pre-pass) | Prism nodes are immutable, so a rewrite re-creates every ancestor and invalidates every identity key and location. `a.push` after rewriting is visibility-checked, so `send(:private_m)` becomes a false positive and `public_send` becomes indistinguishable from `send`. `&:m`, `bind_call` and the 45% of computed names have no faithful rewrite, so consumers keep a second path anyway. It imposes one conservatism on every consumer. |
| Keep per-site logic, share one constant | Twenty-six constants are already equal. The divergences are in extraction, the shift, receiver filtering and policy. A shared three-name constant also invites flattening the three deliberate `public_send` exclusions (`module_function` and `main.include`, whose targets are private, and the `ruby2_keywords` deprecation), which would add false positives. |
| Synthesise `CallNode`s, generalising `literal_send_target` | A copy is a new identity: it misses `TypeOfMemo` and `scope_index` and writes side-table rows nobody reads. It allocates two nodes per use. It looks like a direct call, so visibility fires on `send(:priv)` unless every consumer remembers where it came from. It cannot express `:yielded` or `owner_node`. |
| Resolve reflection only as a `MethodDispatcher` tier | Typing-only. About 30 of the 36 sites are syntactic passes that run without types. The tier survives as WD3, a consumer of the seam. |
| A per-file reflective-call index | One more walk and a run-scoped slot for 0.17% of calls. Only cross-site resolution would justify it, and the criterion excludes that. |
| Make the view an event of ADR-116 WD5's declaration walk | Only `ScopeIndexer` uses that walk. The view has to be the primitive; the walk's call event can carry an `Invocation` later. |
| One migration PR | Against ADR-116's rule that behaviour never rides in a move, and the hot files collide with parallel lanes. |

## Open decisions

Each has a recommendation; the maintainer ratifies them with this ADR.

- **D1 — Must or may, per consumer.** Recommend *may* for the censuses, floors, frame globals, effects
  taint and reachability; *must* for typing, folding, visibility rows, deprecations and sig-gen. The
  matrix records the choice per column.
- **D2 — `public_send` of a private target in typing.** Recommend keeping ADR-5's optimism (type the
  success path, as expression_typer.rb ~2733 documents) and adding no diagnostic. Consumers whose target
  is private (`main.include`, `module_function`, the `ruby2_keywords` deprecation) decline on
  `public_only`. `private_class_method` is public, so its exclusion is an accident S2 removes.
- **D3 — The `copy` adapter.** Recommend quarantining `literal_send_target` behind the ratchet's allowlist
  and retiring it only when the floors take `(node, name, receiver, offset)`; it threads through six
  modules. The `StatementEvaluator` copy passed to `type_of` gets its own issue.
- **D4 — Plugins.** Recommend no plugin exposure until S7, then reconsider under ADR-128.
- **D5 — Type-refined names** (`m = :push; a.send(m)`). Recommend leaving room for a typed constructor and
  not building it until someone measures how many computed names type to a constant.

## Consequences

Positive:

- A spelling is learned in one file, and the matrix shows which consumers honour it.
- The deliberate `public_send` exclusions become `public_only` tests with their reason in the code.
- #1872's wrong type and the user-defined `send` false positive close without synthetic nodes.

Negative:

- S0's matrix is real work before any payoff, and every behaviour slice needs corpus adjudication.
- Making computed names honest (S5) widens: `public_send(attr)` is common in Rails code. One consumer per
  PR, with floor rows (`--require-rows-in`) on shapes that must keep firing.
- Following more sends grows the callee floor's graph (ADR-127); S4 and S5 check wall time.

Carry-over: the role table (WD4) and the frame model are separate. When ADR-116 WD5 ports a walker that
reads calls, its call event carries the `Invocation` as a named variant, under WD5's amendment rule.

## Relationship to other ADRs

- [ADR-116](116-hot-file-restructuring.md) — WD4 is its C1 applied to selector names; WD5's
  pin-then-ratchet and the no-behaviour-in-a-move rule are its guardrails. Its WD5 declaration walk owns
  frames; this ADR owns spellings.
- [ADR-5](5-robustness-principle.md) — D2's optimism, and the reason the seam never picks a conservative
  default.
- [ADR-17](17-monkey-patch-pre-evaluation.md) — the pre-evaluation path the rejected desugaring would have
  reused.
- [ADR-129](129-type-of-result-memo.md) — why the view carries original nodes and keeps no memo.
- [ADR-127](127-callee-floor-graph-budget.md) — the budget S4 and S5 spend.
- [ADR-2](2-extension-api.md) — the plugin surface D4 leaves unchanged.
