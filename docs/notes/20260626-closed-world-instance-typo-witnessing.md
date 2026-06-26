# Candidate ADR — closed-world undefined-method witnessing on in-source instances

Status: future-ADR candidate, recorded 2026-06-26. **Not a decision** — a flagged gap with a
sketched FP envelope, parked behind the adjudication bar. If pursued it becomes an ADR under
the ADR-57 adjudicate-per-firing-class protocol; until then this note is the bookmark.

Grounding: the 2026-06-26 rigor-rs port feedback (item 3 — "in-source instance leniency = a
missed bug"), cross-checked against `lib/rigor/analysis/check_rules.rb` and
`lib/rigor/reflection.rb`.

## The gap

`call.undefined-method` bails before witnessing a typo whenever the receiver's class is not
RBS-known:

```ruby
# check_rules.rb ~L556
return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
```

A project's own model is in-source, has no RBS, so `rbs_class_known?` is false → the rule skips
it. Consequently a real bug — a typo on your own method, called from outside the class —

```ruby
user = User.find(id)   # User defined in app/models/user.rb, no RBS
user.full_naem         # typo; NOT witnessed today
```

is silent. This is the **sound-over-complete** stance (CONTEXT: in-source classes have no
authoritative method table, so enumerating it to prove a call "undefined" risks a false
positive). It is correct as a default, but it misses a frequent, mundane bug class.

The chained variant is partially recovered already: `user.full_name.lenght` can fire via the
tier-4 in-body return inference (ADR-57) once `full_name`'s return is typed. The **direct**
typo on the in-source instance is the residual hole.

## Prior art in-repo — the mechanism already exists for self-calls

`call.self-undefined-method` (ADR-24 slice 4, `self_undefined_method_diagnostics`
check_rules.rb ~L785) **already witnesses this exact bug for the self-call case** — a typo in
`self.full_naem` / implicit-self `full_naem` *inside* the class. It does so with a closed-world
gate that is the template for any extension:

- the receiver class is in-source and **not a module / mixin contract**;
- it **defines no `method_missing`** (`scope.discovered_method?(class_name, :method_missing,
  :instance)`, check_rules.rb ~L880);
- the method set is otherwise treated as enumerable.

So the proposal is **not** new machinery — it is extending that closed-world gate from the
self receiver to an **external receiver typed to an in-source class**.

## Sketch of the candidate tier

Witness `recv.meth` as undefined only when *all* hold:

1. inference typed `recv` to a single concrete in-source class `C` (not `Dynamic`, not a
   union, not RBS-known) — the precision precondition the self-call case gets for free;
2. `C` passes the existing closed-world gate: no `method_missing`, not a mixin/contract,
   and additionally **no `define_method` / `class_eval` / metaprogrammed method injection**
   and no dynamically-mixed module that could add `meth` at runtime;
3. `meth` is absent from `C`'s full discovered ancestor chain (including in-source includes).

On any uncertainty in (1)–(3), decline (today's silence) — never widen toward a firing.

## Why it is deferred (the FP envelope and the ranking)

- **Yield is gated by receiver precision.** It fires only where the receiver was precisely
  typed to the in-source class. On real apps that receiver is frequently `Dynamic` already
  (method chains off framework calls, params, ivars), so the realized catch rate may be low
  relative to the soundness risk — this needs a corpus measurement before the work, per the
  CRuby-stdlib-campaign lesson that survey radius must be sample-adjudicated first.
- **The metaprogramming FP surface is real.** Rails models add methods at runtime in ways a
  static closed-world scan cannot fully see (association/attribute macros, `define_method` in
  concerns, `method_missing` on a *superclass* or included module). The gate must be at least
  as conservative as the self-undefined case and probably stricter, because an external caller
  has less context than an in-body call.
- **Ranks below ADR-58.** Instance-variable field typing (ADR-58) realizes more protection on
  the same model code with no new firing-policy risk; param inference (ADR-67) feeds receiver
  precision this tier depends on. Both are the natural predecessors — this tier is most
  valuable *after* receivers are typed more often, which is exactly what ADR-58/67 do.

## Relationship to existing surfaces

- **ADR-24** (`call.self-undefined-method`) — the closed-world gate to extend; this tier is its
  external-receiver sibling.
- **ADR-34** (`call.unresolved-toplevel`) — the toplevel-self analogue; different receiver.
- **ADR-58 / ADR-67** — precision predecessors that raise the realized yield.

## If pursued

Author as an ADR (`call.undefined-method` closed-world tier), staged WD1 = corpus measurement
of receiver-precision yield on the algorithm + Rails survey corpora *before* implementation;
WD2 = the gate extension reusing `self_undefined_method_diagnostics`'s closed-world predicate;
WD3 = the strict metaprogramming-escape guard; gate green = adjudicated-not-zero-delta (ADR-57
protocol) + hand-probed discriminating shapes (a concern-injected method, an association
accessor, a `define_method` reader) proving each declines.
