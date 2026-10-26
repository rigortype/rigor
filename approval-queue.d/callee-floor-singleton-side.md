# On the singleton side the callee floor also reads the same-named instance def, giving up a true positive

- **PR:** [#2394](https://github.com/rigortype/rigor/pull/2394)
- **Issue:** [#2297](https://github.com/rigortype/rigor/issues/2297)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-26

## Background

The callee mutation floor widens a caller's argument after a self-call whose callee mutates the matching parameter.
Before #2394 it resolved every self-call through the instance-side def table, including one made from a class method
(`def self.run`, or a `def` in `class << self`). That reported on correct code when the singleton callee mutated, and it
lost a true positive when only a same-named instance def mutated:
`def self.stripes(acc) = acc.size` beside an instance `stripes` that mutates. Ruby raises on `acc[0].upcase` there, yet
the floor read the instance def and stayed silent.

The first round of #2394 resolved such a self-call to the singleton def only, which restored that true positive. The
review found five shapes where correct Ruby (each prints `"X"`) then drew a new false positive that the base engine did
not report. In each one the floor follows no path from the singleton side to the code that mutates:

- a facade `def self.call(acc) = new.call(acc)` with a mutating instance `call`;
- `def self.helper(acc) = instance.helper(acc)` with a mutating instance `helper`;
- `module_function` in a form the index does not publish on the singleton side;
- `define_singleton_method(:poke) { |acc| acc[0] = "x" }` beside a mutating instance `poke`;
- `class << self; def real(acc) ...; alias_method :poke, :real; end` beside a mutating instance `poke`.

The facade and the singleton instance are explicit-receiver hand-offs, which #2336 tracks. The other three are
singleton defs the discovery index does not record. The base engine was silent on all five only because it read the
same-named instance def by accident.

## Options and trade-offs

- **Singleton def only.** Matches Ruby's dispatch and keeps the true positive, but every shape above reports on
  correct code until #2336 and the indexing gaps close.
- **Singleton def or the same-named instance def.** The floor applies when either one mutates. All five shapes stay
  silent, as on base. The cost is the true positive above, and any like it: a class method whose own callee does not
  mutate, beside an instance method of the same name that does. The floor only forgets a literal shape, so this
  reading can drop a report but never add one.

## Decision

Singleton def or the same-named instance def, as the coordinator ruled in the #2394 review: false positives outrank
the true positive (AGENTS.md, ADR-5). An instance-side self-call still reads instance defs only. A singleton callee
that mutates is still followed, so the issue's false-positive shapes (`def self.helper`, a singleton chain, `class <<
self`) still stay silent. Two labelled controls in `spec/integration/callee_singleton_send_floor_spec.rb` pin the lost
true positive: "floors an argument only the same-named instance chain mutates" and "floors an argument the same-named
instance def mutates at a singleton chain's next hop".

## To undo

Once #2336 follows explicit-receiver hand-offs (`new.call(acc)`, `instance.helper(acc)`), and the index records
`define_singleton_method` blocks, `alias_method` / `alias` in `class << self` and every `module_function` form as
singleton defs, drop the instance lookup from the singleton branch of `StatementEvaluator#resolve_self_callees`. Then
turn the two controls back into reporting examples, and keep the five shapes' examples (the "with a singleton-side
hand-off the floor does not follow" context), which must stay silent through the new mechanisms.
