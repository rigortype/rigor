# Typing an `attr_reader` call: what it would take, and what it is worth

Date: 2026-10-17.

Status: **research note, no design commitments.** It answers whether `rigor check` (and so `rigor lens`, which
reports what `check` reads) can give a project `attr_reader` / `attr_accessor` reader call a return type. The
engine is `master` at `4f4e8d9ad`. The design was drafted with a design partner and then critiqued adversarially;
both measured the same yield independently.

## Why it came up

ZARD, the documentation consumer of `rigor lens` (#1907), renders Rigor's own `lib/` API. There, every
attribute member's overload return is `unavailable` with `not_computed`, as `docs/internal-spec/lens.md`
§ Members requires: 1,456 reader members, 1,112 of them `single_site`. Lens cannot report a type `check` does
not have, so the question is about `check`.

## What the engine does today

- **A reader call is untyped wherever it is written**, in the owner's own file or in another file. The
  macro records only a name and a kind in `discovered_methods` (`ScopeIndexer#record_attr_methods`), and
  `MethodDispatcher#try_discovered_method` answers a discovered method that has no `def` node with `untyped`.
  The call records `inferred_return_untyped`.
- **A direct ivar read is typed.** `StatementEvaluator#seed_instance_ivars` seeds each instance `def` body
  from the per-class ivar census (`Scope#class_ivars_for`, built by `ScopeIndexer#build_class_ivar_index`).
  - Probe: `@name = "x"` in `initialize`, then `take(@name)` against `take: (bool) -> void`, reports `got "x"`.
  - In the same class, `take(name)` reports nothing.
- **The census is per file.** `Runner#project_scope_seed_tables` does not seed it. A reader in another
  file, or a reopening of the class in another file, sees an empty table for that class.
- **The call-site re-typing of a `def` body does not seed ivars either.** `ExpressionTyper` types a callee
  body through `build_user_method_body_scope`, which binds parameters only. A trivial `def name = @name`,
  read through a call, is untyped exactly like the macro. Lens still reports that def's `body_return` as the
  literal, because lens reads the definition's own main-walk index.
- **ADR-58 is out of date on one point.** Its line 250 says "accessor returns drop the nil (`x.parent` on a
  `Node` reads `Node`)", which no longer describes the engine.

## The yield, measured before designing

`rigor lens` and `rigor sig-gen --format=json` were run over Rigor's `lib/` (587 files). The 1,109 instance
`single_site` readers were then joined with the ivar seed that sig-gen maps to each accessor. sig-gen applies
the same mapping any reader mechanism would read.

| The reader's ivar seed | Readers |
| --- | --- |
| Concrete, nil-free (`Set`, `0 \| Integer`, a tuple) | 30 |
| Concrete but nil-able | 1 |
| Contains `untyped` (766 pure `untyped`) | 781 |
| No entry (sig-gen skipped it) | 297 |

The 1,078 untyped readers are almost all `@x = x` from a constructor parameter. The census types each rvalue
with no local bindings, so a parameter is `Dynamic[top]`, even when `sig/` declares a typed `initialize`.
kramdown gives 27 readers, of which 18 are `single_site` and 1 is typed. The critique re-derived the counts
from the same data.

So **the reader is the right seam, but almost nothing flows through it**. On its own, a reader mechanism moves
ZARD's number from 1,112 `unavailable` to about 1,082. The floor is constructor-parameter typing.

## The candidate mechanism, and the holes the critique found in it

**Part A** is a reader answer inside the discovered-method tier. `try_discovered_method` would return,
before its `untyped`, the owner's census entry for `@name`, widened to its erasure (never a literal; `true` or
`false` reads `bool`, because `FalseClass` folds falsey). It would be gated as follows:

- the macro is a certain direct statement of the class body;
- the class is declared in one file;
- no project subclass overrides the reader;
- any `nil`, `Dynamic` or `Bot` constituent declines, leaving today's `untyped`.

The design partner rejected two alternatives:

- a cross-file published census, an analogue of the #644 constant publication, which needs a fold rule, a new
  edge kind and a snapshot schema bump;
- synthesizing a `@name` body and reusing the def path, which yields `Dynamic` as the previous section shows.

The adversarial critique found four defects that make Part A, **as drafted**, emit wrong types or diagnostics
on correct code:

1. **A nil from a read before any write is invisible.** The census joins `nil` only when a sibling `def` reads
   the ivar before writing it and `initialize` does not write it. A reader is not a `def` body, so it never
   counts as that first read.
   - `attr_reader :data; def load = @data = { a: 1 }` maps `data` to `{ a: 1 }`, and `@v = 1 if flag` in
     `initialize` maps `v` to `1`. Both readers return `nil` at runtime.
   - Amendment: type a reader only when an unconditional top-level statement of `initialize` (or of an
     ADR-38 initializer) writes its ivar.
2. **A later redefinition that is not a `def` is missed.** The override gate reads `discovered_def_nodes`
   only, and looks down the hierarchy only.
   - `define_method(:name) { "s" }` after the macro is missed, and so is a `prepend`ed module that defines
     `name`.
   - Amendment: reuse `SelfCallIvarWrites#single_definition`, which already combines possible definitions,
     opaque envelopes, multiple class sources and the class edge. Build the redefiner set from
     `discovered_methods` (any spelling), and decline when the owner prepends anything.
3. **`instance_variable_set` is already a false positive, and a reader would spread it.** The census never
   looks at it. With `@timeout = 5` followed by
   `options.each { |k, v| instance_variable_set(:"@#{k}", v) }`, `@timeout.end_with?("s")` reports
   `undefined method 'end_with?' for 5` today. The concrete repro is now on #1931.
   - Amendment: decline when the owner's body calls `instance_variable_set`, or `send` / `public_send` with
     a non-literal or `=`-suffixed name. Decline when it includes or prepends a module, and measure that cost.
     Better, fix #1931 first.
4. **A module owner is wrong.** `module M; attr_reader :x; def setup_m = @x = 1; end`, included by a class
   whose `initialize` writes `@x = "s"`, maps `M#x` to `1`. A receiver narrowed to `M` (by `is_a?`, or by an
   RBS parameter) then reads the wrong type. Amendment: class owners only.

It also raised four medium points:

- **Incremental edges.** The single-file gate needs `ResolutionChain.record_class` (a read site on every
  declaring file) as well as `read_missing(:class)`. Otherwise removing a reopening serves a stale `untyped`
  and fails `--verify-incremental`. The override gate's ancestry edges are filed only on a memo miss, so they
  must be filed outside the memo.
- **Runtime subclasses.** An implicit-self call inside the owner's own methods often runs on a subclass
  instance that writes the ivar differently. A gate that declines when any discovered subclass exists needs
  measuring.
- **Lens would over-claim.** `check` would type a reader only at call sites in the owner's own file, because
  the census is per file. Lens's constant `value` already reports the reading from another file
  (`docs/internal-spec/lens.md` § Sites). A typed attribute slot would therefore claim more than most callers
  get. Reporting `dynamic` for declined readers would turn about 1,082 `unavailable` slots into
  `() -> untyped` overloads that carry no new information.
- **Part B is larger than it looks.** Part B binds `initialize` parameters in the census from a declared
  signature (RBS or rbs-inline). Because the census is flow-free, binding at entry is wrong when the parameter
  is reassigned before the write (`x = Integer(x)`), and an overloaded `initialize` needs a decline.
  - It changes every direct `@x` read that `seed_instance_ivars` seeds, not only readers.
  - It needs its own corpus gate, and should bind only parameters the body never writes.

## Recommendation

- **Do not land Part A on its own.** Once amended, it types at most 30 lens members on Rigor's `lib/` and 1 on
  kramdown, and `check` gains them only at call sites in the owner's own file.
- **The lever is Part B**, under the constraints above, measured as its own slice on the ADR-58 corpus with
  `tool/engine_diag_diff.rb`. Only 18 of the 270 `single_site` reader owners in Rigor's `lib/` appear in
  `sig/` at all, and 8 of them declare a typed `initialize` covering 50 readers. So its yield grows with
  declared constructors, not with the engine.
- **Part A then rides on Part B**, with the four amendments, cross-file reach decided separately (an ADR-46
  amendment), and lens keeping `unavailable` for a declined reader.
- **Fix #1931 first.** Its false positive exists today, independently of any of this.
- **Tell ZARD the floor now.** Most attribute types are unavailable because constructor parameters are
  untyped, not because lens leaves them out.

## Decisions for the maintainer

1. Whether to pursue Part B (an ADR-58 amendment: declared constructor parameters bind in the census), and
   with which corpus gate.
2. Whether Part A is wanted at all while its reach is the owner's own file. That is a lens contract question:
   § Sites reports the reading from another file.
3. Whether cross-file reach (a published census) is worth an ADR-46 amendment, given the yield above.
