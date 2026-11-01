# A splat argument floors the array's elements and every local their type could be, and a rest parameter's write is read from its uses

- **PR:** [#2611](https://github.com/rigortype/rigor/pull/2611)
- **Issue:** [#2515](https://github.com/rigortype/rigor/issues/2515)
- **Class:** open-choice
- **Precedent:** [#2570](https://github.com/rigortype/rigor/pull/2570)
- **Decided:** 2026-11-02

## Background

`args = [parser, options]; Opts.add_format(*args)` hands the hash through an array, so the per-parameter floor never
saw it. The brief said the array's elements are the caller's literal-carrying locals, but a local's type is all the
scope records: a tuple type does not name the locals its elements came from.

## Options and trade-offs

- Floor the element in the array local's type, in every other carrier local whose type a written element type accepts
  (a subtype or equal: `args << options` widens a pushed `{ format: "text" }` to `Hash[Symbol, String]`), and in every
  element of the array holding the same type. It needs no new state and reads the array's type at the call, so a push,
  an index store, a conditional binding (`Tuple?`) and a union of arrays are all covered, member by member, with the
  any-slot rule for a union. A local bound to the array's own type (`args2 = args`) is rebound. A local matched this
  way is a guess, so it floors gradually (a `String` carrier to `Dynamic[String]`): it may forget a fact, never add a
  finding. A `Dynamic` element matches no local, which would floor every carrier in scope; a push that types as `Dynamic` (`args = [1]; args << options`, `args = [1, 1]; args[1] = options`) therefore leaves the source local unfloored, a false positive kept as on base. The cost is precision: an
  unrelated local with a compatible type floors too, and a local whose type no element accepts is not matched.
- Record the origin locals of an array literal in the scope. Exact, but a new scope fact with its own invalidation
  (the array mutated, the local rebound) and allocation cost on every array literal.
- For a callee's rest parameter, which the own census does not track, read the body: written when the rest is read
  other than as a splat argument of a call, or splatted into a call that resolves to a writer or to a def with a rest
  of its own. A full rest census would be exact and was not built: it needs its own slot kind through the chain graph.

## Decision

The first option and the body reading. They only add floors, and they add no scope state and no run-scoped memo (the
rest census is a `def_census` kind, an AST property). Forwarding is read one hop.

## To undo

Remove `floor_splat_arguments` and its call in `floor_callee_escaped_args_for_call`, the `SplatNode` case in
`call_passes_local_argument?`, and the `:rest_uses` census. `spec/integration/callee_splat_floor_spec.rb` pins each part.
