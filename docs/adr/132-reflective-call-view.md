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
these. Thirty-six sites in `lib/` recognise the `send` family themselves, through twenty-three separate
constants equal to `%i[send __send__ public_send]`. They include the censuses, the mutation floors,
`$~` / `$_` rebinding, return barriers, visibility and `module_function` state, `ScopeIndexer`'s definer
walkers, effects, reachability, sig-gen, check rules and the typer's literal-send shortcut. A further
thirteen files classify `&:sym` independently, and one rule models method-handle chains.

The sites disagree on the same spelling, and the disagreement is not in the name list:

- **Extraction.** `send("push")` is a call of `push` for about 28 sites and not for the rest, which read
  only a `SymbolNode`. Only one site reads the literal fragments of `send("#{m}_x")`.
- **The argument shift.** Eleven sites drop the selector argument by hand. The typer does not, and passes
  the outer node with the inner argument types to dispatch, so `send(:Integer, "1", exception: false)`
  types `Integer` where the direct call types `Integer?` (#1872).
- **Policy for a computed name.** Seven sites give seven answers: taint, `reached!`, `any_entry`, open
  world, "does not clear", `nil`, decline.
- **Missed spellings.** `send(:define_method) { }` is counted by the ivar census and not narrowed by the
  block-self rule, so the two disagree about the same block (#2167).

Every fix lands in one consumer, and the next review finds the same spelling missing in another. The goal
is that a spelling is learned once and every consumer sees it the same way, while each consumer still
decides for itself what an unknown name means.

The payoff is consistency and review cost, not precision. Reflective spellings are rare: the `send` family
is 0.167% of 1.66M call nodes in the survey corpus, metaprogramming selectors reached through `send` are
0.010%, and 45% of sends have no literal name. Of the 27 issues the inventory maps to these sites, the view
closes three outright (#1872, #2167, #2704), removes one item from about eleven, and does not touch about
twelve (receiver resolution, closures, eval semantics). This ADR does not promise the last group.

Two findings bear on the design:

- `try_literal_send` assumes every `send` is `Kernel#send`. `Mailer.new.send(:hello, 0).even?`, with
  `Mailer#send(message, flags)` defined, reports `call.undefined-method` for `"0"`; Ruby prints `false`.
  Only the SymbolNode-only extraction keeps `sock.send("payload", 0)` out of the same trap, so widening the
  typer to String names is unsafe on its own.
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
and whether Ruby checks visibility. Anything that needs more than the subtree stays with the consumer:
types, method tables, a local's bindings, parent or sibling nodes, the meaning of a code string, and the
conservative answer for an unknown name.

Applied:

| Spelling | In the view? | Why |
|---|---|---|
| `send` / `__send__` / `public_send`, nested too | yes | all four facts are in the subtree; the name may be exact, a pattern, or computed |
| `r.method(:m).call(a)`, `.()`, `[]`, `===`; `M.instance_method(:m).bind_call(o, a)`, `.bind(o).call(a)` | yes | the handle is in the receiver chain |
| `&:m`, `&r.method(:m)` | yes | `self` is the value the carrier yields, a role and not a node |
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
  def may_name?(inv, name)     # false only when the subtree proves the name cannot be `name`
end
```

- `node` is the analysed tree's own node: the outer `send` / `.call` / `bind_call` `CallNode`, or the
  `BlockArgumentNode` for block-pass (what `ExpressionTyper#apply_hash_block` already passes as
  `call_node:`, expression_typer.rb ~6642). It is the only thing a consumer keys on or reports at.
- `method_name` is a Symbol through `SymbolName.of`, which owns the encoding guard, or `nil` when no literal
  fixes it. `nil` means "not known", never "no call". `name_node` is the operand that spells it, for
  DiscoveryIndex rows (built from its location, as `record_definer_name_row` does) and partial reads.
- `argument_offset` is where the target's arguments start in `node.arguments.arguments`: 1 per `send`
  level, 0 for `.call`, 1 for `bind_call`, `:yielded` for block-pass. The arguments are the tree's own
  nodes, so `type_of(arg)` keeps hitting the memo; a consumer that needs them as an Array slices them.
- `self_node` is a node, `:implicit`, or `:yielded`. For `r.method(:m).call` it is `r`, because the
  capture happens at `method`. `owner_node` is set only for `instance_method` chains: lookup starts at
  that module's instance side, not at `self`'s class.
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
4. **Look like a `CallNode`.** No field shares a name with a `Prism::CallNode` reader, so passing an
   `Invocation` where a call node is expected fails at once. #1872 was a value that half-corresponded.
5. **Read outside the subtree.** No parent walks, no locals, no code strings, no framework spellings.
6. **Classify selectors.** It does not know that `define_method` defines or that `instance_eval` rebinds.
   The role names live in a separate table (WD4).
7. **Change the plugin API.** Plugins keep `call_node` (ADR-2). Exposure waits until the value has
   settled (D4).

### WD3 — Dispatch reads argument nodes through the offset

`MethodDispatcher`'s call context gains `argument_offset` (default 0), and the tiers that read
`call_node.arguments` read through `ArgumentNodes.for(context)` instead: `RbsDispatch#splat_indices`
(~1502), `#plain_positional_arguments?` (~1835), `#class_factory_argument?` (~2011, which has no size check
today and reads the selector as an argument), `InterfaceShape` (~119), `KernelDispatch` (~268),
`HashTransformKeysFolding` (~167), `SetFolding` (~108). `try_literal_send` then dispatches with
`call_node: inv.node` and the offset. The side tables stay keyed by the node the user wrote, and every
tier sees the argument list the direct call would give it. The context stays in its 160-byte slot at that
field count (measured).

The typer takes the shortcut only when the receiver's `send` is genuine: every member of the receiver type
resolves `send` to `Kernel#send` / `BasicObject#__send__`, with no project or RBS override. `__send__` and
`public_send` keep it. Syntactic consumers need no such check: reading `sock.send("x", 0)` as a call of `x`
over-approximates a census, which is the false-positive-averse direction, and must-consumers already
restrict the receiver to `self` or implicit.

### WD4 — Selector roles are declared once

`Source::ReflectiveCall::Spellings` holds frozen Symbol Sets by role: the view's own (`SENDERS`,
`PUBLIC_SENDERS`, handle readers, invokers, binders) and the roles consumers check after unwrapping
(`BLOCK_EVALUATORS`, `STRING_EVALUATORS`, `DEFINERS`, `SINGLETON_DEFINERS`, `ALIASERS`, `IVAR_WRITERS`,
`CONST_WRITERS`, `VISIBILITY_SETTERS`, …). A consumer that wants a narrower set writes it as an expression
over the roles with its reason beside it. Some differences are legitimate — `MatchRebinding::SelfCalls`
keeps `EVALS = {eval}` because only `eval` shares the caller's `$~` frame — so this is a role table, not
one list, and today's ten unequal eval sets become visible arithmetic. This is ADR-116's C1 ("declare
each kind once") applied to names.

### WD5 — Pin before moving, ratchet after

The corpus holds too few reflective spellings to prove a move preserved behaviour. So two specs land
first, at today's answers:

- **The spelling matrix** (`spec/rigor/inference/reflective_spelling_matrix_spec.rb`). Rows are spellings:
  the three senders × Symbol / String / interpolated / computed / splat names × implicit / `self` /
  constant / other receivers, nested senders, handle chains, `bind_call`, `&:m`, `&r.method(:m)`. Columns
  are consumer families: typing, callee floor, ivar census, global census, visibility, `module_function`,
  definers, mixins, effects, `$~` / `$_`, Lens. Each cell is "same as the direct call" or a declared
  exception with a reason or an issue number. Paired consumers (#2167's census and narrowing) assert equal
  columns.
- **The source ratchet** (`spec/rigor/source/reflective_spelling_ratchet_spec.rb`). A Prism scan of
  `lib/**/*.rb` counts SymbolNodes naming a sender, handle reader or binder (both `%i[]` and `Set[...]`
  notations; 39 literals today) against an exact per-file table, in the style of
  `spec/docs/plugin_io_boundary_spec.rb`. A count that differs in either direction fails, so a slice
  lowers its row. It also allows Prism `.copy(` only at its existing callers.

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
| S1 | Re-seat the four partial views and `CalleeWriteCensus.literal_send?`; then port the sites whose extraction already equals the view's, one family per PR (censuses; frame globals and flow; `ScopeIndexer`; rules, reachability, sig-gen, effects) | pure | constants 23 → ~5 |
| S2 | SymbolNode-only sites read String names too (deprecations, return barrier, repeated `\|\|=`, `send_extend?`); not the typer | behaviour | divergence 1 outside typing |
| S3 | WD3: the offset channel, the genuine-`send` check, then String names in the typer | behaviour | #1872, the user-defined `send` false positive |
| S4 | Sites that miss `send`: `DefineMethodBlockSelf` with `Scope#block_self_narrowing_unknown?` and `CensusForeignBlock` in one PR; Lens `visibility_call?`; `LexicalMethodSites` | behaviour | #2167; items of #2160, #2087, #2984 |
| S5 | Computed names, one consumer per PR, starting with the alias floor through `may_name?` | behaviour | #2704; items of #2697, #2376 |
| S6 | Block-pass readers on `block_pass` | behaviour | items of #2913, #1417 |
| S7 | Consumers of role sets move onto WD4 and see these calls through `send` | behaviour | items of #3057, #2983, #1377 |

The seam is done when the ratchet reads zero outside `reflective_call.rb` (apart from allowlisted
type-level uses such as `ConstantFolding`), every matrix cell is answered, and a new spelling is one edit
in the seam plus one matrix row.

## Rejected alternatives

| Alternative | Why not |
|---|---|
| Desugar the AST before analysis (a Prism rewrite, or an ADR-17-style pre-pass) | Prism nodes are immutable, so a rewrite re-creates every ancestor and invalidates every identity key and location. `a.push` after rewriting is visibility-checked, so `send(:private_m)` becomes a false positive and `public_send` becomes indistinguishable from `send`. `&:m`, `bind_call` and the 45% of computed names have no faithful rewrite, so consumers keep a second path anyway. It imposes one conservatism on every consumer. |
| Keep per-site logic, share one constant | Twenty-three constants are already equal. The divergences are in extraction, the shift, receiver filtering and policy. A shared three-name constant also invites flattening the three deliberate `public_send` exclusions (`module_function`, `main.include`, `private_class_method`), which would add false positives. |
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
  success path, as expression_typer.rb ~2733 documents) and adding no diagnostic. Consumers whose effect
  differs (`main.include`, `module_function`, `private_class_method`) decline on `public_only`.
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
