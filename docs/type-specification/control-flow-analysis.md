# Control-Flow Analysis

Rigor performs flow-sensitive type analysis in the style of PHPStan, TypeScript, and Python type checkers. The analyzer refines types by guards, returns, raises, loop exits, pattern matches, equality comparisons, predicate methods, and plugin-provided facts.

This document defines:

- the structure of edge-aware scopes;
- how a non-local exit contributes to the value of the construct it leaves;
- supported narrowing sources;
- Ruby equality semantics for narrowing;
- fact stability, invalidation, and mutation effects;
- the shipped narrowing surface and what is still deferred.

The flow-effect bundle schema used by `RBS::Extended` annotations and plugin contributions is in [rbs-extended.md](rbs-extended.md).

## Edge-aware scopes

The type environment is refined by guards, returns, raises, loop exits, pattern matches, equality comparisons, predicate methods, and plugin-provided facts. Each expression is analyzed with an input `Scope` and produces output scopes for the relevant edges:

- normal completion;
- truthy condition result;
- falsey condition result;
- exceptional or non-returning exit;
- unreachable result, represented by `bot`.

These scopes carry both **positive facts** and **negative facts**. Joins merge those facts conservatively.

Edge-aware scopes are finer than assigning one scope to the whole `if` condition. Short-circuiting expressions update the scope between operands:

- `a && b` analyzes `b` in the truthy scope produced by `a`.
- `a || b` analyzes `b` in the falsey scope produced by `a`.
- `!a` swaps truthy and falsey scopes.
- A conditional used as a condition, `(p ? q : r) ? … : …` in any spelling, carries the facts of its `&&` / `||` equivalent: it is truthy through `p && q` or `!p && r` and falsey through `p && !q` or `!p && !r`, so `(s.nil? ? false : x.finite?) ? x : 0.0` narrows `x` as `(!s.nil? && x.finite?) ? x : 0.0` does. An arm whose value is settled, such as a literal `false`, contributes only its live edge, unless its truthiness rests on an optimistic lookup. The facts are derived through at most two stacked conditionals; a taller stack contributes no narrowing.
- `unless a` uses the same condition facts as `if a`, then swaps branch destinations.
- `case`, pattern matching, and chained `elsif` expressions pass negative facts from earlier arms to later arms.
- The ternary `a ? b : c`, the modifier `b if a` / `b unless a`, and the block forms are one construct: each MUST narrow its arms from the same condition facts, and the value of a conditional MUST be the same whether it is a statement or a value — an argument, a receiver, a collection element, or the right-hand side of a write. A Float comparison's falsey arm keeps the entry type in every spelling, because `!(x > c)` also holds for `NaN`.
- `a && b` and `a || b` are the same construct in every position: the value of `x.finite? && x` MUST be the same whether it is a statement or a value, and so MUST the short-circuit on a constant left operand (`false && b` is `false`, `1 || b` is `1`). That short-circuit MUST NOT drop the right operand when the left operand's nil-freeness is optimistic, such as a dynamic-key read of a `Hash[K, V]` typed past its signature's `%a{implicitly-returns-nil}`, because the lookup can miss. (A computed-key read of a closed, non-empty hash shape is not optimistic: the shape answers the miss with `nil` outright.) The falsey edge of a Float comparison keeps the entry type here too.

```ruby
def contradictory(foo)
  # Assume `foo` has a finite literal domain and ordinary String equality.
  if foo == "foo" && foo == "bar"
    p foo # Rigor type: bot; this edge is unreachable.
  end
end
```

The right side of `&&` is analyzed after the left side's true fact has refined `foo` to `"foo"`. The true edge of `foo == "bar"` then intersects `"foo"` with `"bar"`, normalizes to `bot`, and marks the body as unreachable. Rigor SHOULD be able to report the contradiction at the comparison or at the unreachable body, depending on diagnostic policy.

For `||`, the same precision applies in the opposite direction:

```ruby
def impossible_after_or(foo)
  # Assume `foo` has a finite literal domain and ordinary String equality.
  if foo == "foo" || foo == "bar"
    p foo # Rigor type includes only the "foo" and "bar" alternatives.
  else
    p foo # Rigor type excludes both "foo" and "bar".
  end
end
```

## Non-local exits

A `return`, `next`, or `break` produces no value at its own position; its type is `bot`, which absorbs under union so a branch join collapses to the arms that can complete. The value it carries out belongs to the construct it leaves, and the inferred value of that construct MUST be the union of its fall-through result with every such arm the analysis reaches:

- `return value` leaves the enclosing method and joins that method's inferred return type. A nested `def` or lambda is a barrier — those returns belong to the inner definition — while a `return` written inside a block still exits the enclosing method and still joins there.
- `next value` ends the current block invocation and makes `value` that invocation's result, so it joins the **block's** value type. A bare `next` contributes `nil`. A nested block, lambda, `def`, or loop retargets a `next` written under it, and such a `next` MUST NOT join the outer block's value.
- `break value` terminates the yielding **call** and is that call's value, not the block's. It MUST NOT join the block's value type; the call's inferred type MUST instead be the union of the result the callee would produce with every reachable `break` arm. A bare `break` contributes `nil`. A nested block, lambda, `def`, or loop retargets a `break` written under it — such a `break` belongs to that inner construct and MUST NOT reach the outer call. Because the union sits above the precision folds rather than inside them, a fold stays free to answer precisely for the path on which the block never breaks. The callee's result stays in the union because an arbitrary callee may return without running the block; the one exception is a callee known to yield exactly once before returning, where an unreachable normal completion of the block removes it (§ "Block call timing"). A call that stores its block without running it — `lambda { … }` and `proc { … }` reaching `Kernel`, `define_method` / `define_singleton_method`, and `Proc.new`, `Thread.new` / `start` / `fork`, `Fiber.new`, `Enumerator.new` and `Hash.new` — has no `break` arm at all: the block does not run during the call, so a `break` in it returns from the lambda or the defined method, or raises `LocalJumpError`, when the stored block later runs, and MUST NOT join the call's value.

An arm on a branch the analysis has proved unreachable is never taken and contributes nothing. Dropping a *reachable* arm reports the fall-through as if it were the whole answer, which reads as precision the program does not have: `ops.all? { |o| next false unless o; true }` types as `true`, the predicate folds to a constant, and correct code is warned about ([#841](https://github.com/rigortype/rigor/issues/841)) — and the same shape written with `break` warns the same way when the arm never reaches the call ([#853](https://github.com/rigortype/rigor/issues/853)).

## Yield value

`yield` runs the block the CALLER supplied, so its value is that block's value. The three exits above carry a value *out* of a construct; this is the one that carries a value back *in*.

- When a method body is re-typed on behalf of a known call site — the inter-procedural return inference — a `yield` in that body MUST type as the value type of the block written at that call site, computed in the call site's own scope. When no caller is known (the analysis of a `def` in its own right), `yield` MUST type as `untyped`.
- The block's value reaches the caller's return only by ordinary evaluation of the callee's body, never by recognising that a method yields: `def wrap; yield; end` returns it, `def announce; yield; "done"; end` returns `"done"`, and a `rescue` arm or a conditional `yield` unions the way any other body would. Inferring a wrapper's return from the presence of a `yield` would invent a type wherever the wrapper substitutes its own value.
- A `yield` written inside a block, a lambda, or a loop still names the enclosing **method**'s block, so those constructs are not boundaries here (unlike the retargeting they perform for `next` / `break`). A nested `def`, `class`, `module`, or `class << self` body begins a new method-block binding, and a `yield` inside one MUST NOT read the outer call's block.

Without this, a method whose whole value comes from a yielding helper is `untyped` at every position, `sig-gen` declines it, and every caller inherits the opacity — while the same logic written inline is typed. Since the wrapper is what a scoped concern (`with_run`, save/restore, instrumentation) is normally written as, the loss followed the better structure ([#720](https://github.com/rigortype/rigor/issues/720)).

## Supported narrowing sources

Supported narrowing sources include:

- Trusted equality and inequality checks against literals and singleton values.
- `nil?` checks and nil comparisons.
- Truthiness checks, where `nil` and `false` narrow the false branch.
- `is_a?`, `kind_of?`, `instance_of?`, and class/module comparisons.
- `respond_to?` checks when the method name is statically known. See [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md) for the visibility rules.
- `Hash#key?` / `#has_key?` against a literal Symbol/String key, when the receiver is a hash shape carrying that key as optional. The true branch promotes the key to required so a subsequent index read drops the optionality `nil` (the value's own intrinsic `nil` is preserved — key presence does not imply a non-nil stored value). The false branch is the conservative no-op. This is the Ruby analogue of a set-theoretic `is_map_key`-style key-presence refinement.
- `Array#empty?` / `#any?` / `#none?` (bare, no block or args) when the receiver is an `Array[T]`. The edge that implies "at least one element" — the false edge of `empty?` / `none?`, the true edge of `any?` — refines the receiver to `non-empty-array[T]`, so length-returning methods (`size` / `length` / `count`) read `positive-int`. The opposite edge is a no-op (`any?` / `none?` being false does not imply emptiness). A Ruby analogue of a non-empty (`tuple_size`-style) collection refinement. The refinement describes the receiver's *content*, not its binding, so an in-place mutator that can empty the receiver (`clear`, `pop`, `shift`, `delete_if`, …) MUST invalidate it: the binding widens back to `Array[T]` and a later `size` reads the base `non-negative-int` envelope again. Retaining the refinement past such a call folds `arr.size == 0` to a constant and reports a false always-falsey condition on correct code.
- Pattern matching and case analysis.
- Predicate methods registered by Rigor plugins.
- Assertions and guards described in `RBS::Extended` annotations (see [rbs-extended.md](rbs-extended.md)).

## Negative facts

Negative facts are first-class scope facts. Rigor SHOULD preserve facts such as "not nil", "not false", "not this literal", and "does not have this nominal class" when they improve later diagnostics.

A negative fact is **domain-relative**: it removes values from the value's already-known positive domain. It MUST NOT introduce a new positive domain from the right-hand side of a comparison. The complete semantic and display rules for negative facts are in [type-operators.md](type-operators.md).

Python's `TypeGuard` and `TypeIs` are useful reference points for predicate effects. A predicate that refines only the true branch is `TypeGuard`-like. A predicate that refines both true and false branches is `TypeIs`-like; internally, the false branch SHOULD be modeled as intersection with a complement, such as `A & ~R`, or as an equivalent difference type.

## Ruby equality semantics

Ruby equality is method dispatch. A syntactic comparison such as `foo == "foo"` calls `foo.==("foo")`, and arbitrary classes MAY override that method. Rigor MUST therefore distinguish:

- **identity facts**, such as `x.equal?(obj)`, which can prove singleton identity;
- **nil and boolean checks**, which are stable Ruby value tests;
- **equality facts for known built-in domains** whose dispatch target is stable, such as finite `String`, `Symbol`, `Integer`, `true`, `false`, and `nil` alternatives already present in the receiver domain;
- **comparison facts contributed by RBS or plugins** for trusted predicate and equality methods;
- **unknown equality methods**, which SHOULD produce at most a relational fact unless the analyzer has enough method information to refine the value type;
- **floating-point comparisons**, which MUST NOT produce literal narrowing by default because `NaN`, signed zero, infinities, and coercion make exhaustiveness and equality reasoning easy to misstate. A relational comparison (`<`, `<=`, `>`, `>=`, `between?`) of a `Float`-typed local against a numeric literal MAY narrow its **truthy** edge to the `Float` range the comparison implies (`x > c` → `Float[c..]`, `x < c` → `Float[...c]`; [ADR-109](../adr/109-ruby-native-range-notation.md) WD5) and MUST keep the entry type on the falsy edge, because `!(x > c)` is also true of `NaN`. `x.nan?` MAY narrow only its falsy edge (to `non-nan-float`) and `x.finite?` only its truthy edge (to `finite-float`).

Equality narrowing MUST NOT introduce a positive domain from the compared value alone. If `foo` is raw `untyped`, `foo == "foo"` keeps `foo` as `Dynamic[top]` with a dynamic-origin relational fact unless Rigor also knows that the dispatched equality method has a trusted narrowing effect. If `foo` is already known to be `"foo" | "bar"`, the same comparison MAY narrow the true branch to `"foo"` and the false branch to `"bar"`.

### Equality trust levels

Rigor SHOULD classify equality facts by trust level:

- **Identity facts from `equal?`** are value facts as long as the observed reference itself remains stable.
- **Built-in literal-domain equality** can narrow only inside an already-compatible receiver domain with a known core dispatch target.
- **`Module`, `Class`, `Range`, `Regexp`, and `===`-based case behavior** need explicit per-kind rules or plugin facts rather than being treated as general equality.
- **User-defined `==`, `eql?`, `===`, and coercion-sensitive comparisons** remain relational facts until RBS metadata or a plugin declares true-edge and false-edge effects.

The initial trusted equality surface is intentionally narrow:

- `equal?` produces an identity fact bound to the observed reference. The fact is invalidated by reassignment, alias-escaping mutation, unknown calls, or plugin-declared effects.
- Built-in literal-domain equality is trusted only for finite literal sets of `String`, `Symbol`, `Integer`, booleans, and `nil`, and only when the receiver dispatch target is known and the receiver domain is already compatible.
- `Float` literal (equality) narrowing is refused by default. Relational comparisons narrow the truthy edge to a `Float` range as above; relational facts MAY still be kept for diagnostics.
- `Range`, `Regexp`, `Module`, `Class`, and `===`-based case behavior MUST NOT produce general value-narrowing facts on their own. They require specific narrowing rules or RBS/plugin effects before they can refine value domains.
- User-defined `==`, `eql?`, and `===` are promoted from relational facts to value facts only through explicit RBS metadata, `RBS::Extended` flow effects, or plugin-declared true-edge and false-edge facts together with any required stability or purity assumptions.

### Regexp match-predicate narrowing

The `Regexp` "specific narrowing rule" the trust levels above defer to is the `=~` match-predicate rule. A `subject =~ pattern` (or `pattern =~ subject`) predicate binds Ruby's regex match globals on its edges, and this is the only Regexp construct that produces value-narrowing facts without an RBS or plugin effect.

- **Pattern-operand recognition.** Exactly one operand MUST resolve to a regex pattern: either a syntactic regex literal, or a constant reference whose type is a value-pinned `Regexp` literal (so `RE = /.../` and `RE = Regexp.new(...)` participate through the constant, resolved by the same lexical-constant lookup the analyzer uses for constant reads). The rule MUST decline (no narrowing on either edge) when NEITHER operand resolves to a regex, when BOTH do (no string subject to bind), when a constant operand types as a union of more than one value (a twice-assigned constant, where no single pattern can be pinned), or when the resolved pattern is compiled in extended (`/x`) mode — a comment or free-spacing `(` cannot be distinguished from a capture group by the participation analysis, so its group indices are untrustworthy.
- **Truthy edge** (the match succeeded — `=~` returned an `Integer` position): `$~` narrows to `MatchData`; `$&`, `` $` `` and `$'` narrow to `String` (they are non-nil on any successful match regardless of grouping); each *unconditionally participating* numbered group `$N` narrows to `String`; `$+` (the last matched group) narrows to `String` only when at least one group participates unconditionally.
- **Falsey edge** (no match — `=~` returned `nil`): `$~`, every unconditional `$N`, and `$+` (when gated in) narrow to `nil`.
- **Participation** is one-directional and conservative. A numbered group participates unconditionally only when neither it nor any enclosing group carries a zero-permitting quantifier (`?`, `*`, `{0,…}`) and it does not sit inside an alternation (`|`) branch; `(?:…)` and lookaround do not capture. A group that is optional, alternation-reachable, or otherwise in doubt is treated as conditional — its `$N` stays `String | nil` on both edges — because a successful overall match can leave such a group unmatched (`nil`) at runtime. `$+` follows the same gate: a zero-group or all-optional-group pattern leaves it `String | nil`.
- **Invalidation.** The match globals are frame-local facts. Ruby keeps them in the special-variable slot of the method body (or class, module or file body) that runs the match. A block, and a closure created in that body — a lambda literal, `lambda {}`, `proc {}`, `Proc.new {}` — ordinarily reaches the same slot, so a match it runs rebinds the body's globals. A nested `def`, class or module body has a slot of its own, and so does every call into a method defined in Ruby: a match in the callee's body rebinds the callee's slot, never its caller's, so `log("parsed")`, `warn "debug"` or `self.log("x")` between the predicate and a global's use leaves the narrowing in place. The caller's slot is reached only by C code that matches on its behalf, by code evaluated in its frame, and by a block or closure it created. An intervening call that may reach it, between the predicate and a global's use, invalidates the narrowing:
  - a match-capable call: one whose method name may run a match, on any receiver;
  - an implicit-self or `self.` call that reaches the slot although its name does not run a match: `eval`; `instance_eval`, `class_eval` or `module_eval` with an argument (their String form; the block form is a block); `send`, `__send__` or `public_send` whose method-name argument is not a Symbol or String literal, or names a method this rule or the one above counts; `self !~ re`, `~self`, `start_with?`, `byteindex`, `byterindex` and `self[re] = s`, which a `String` or `Regexp` subclass inherits and which set their caller's globals; and `any?`, `all?`, `none?` or `one?` with an argument, which run `pattern === element` from C even when the class's `each` is written in Ruby. Such a call also invalidates when an argument holds a call that may match (`log(line.sub(/=/, ": "))`), because the argument runs in this frame;
  - `yield`, and a `call`, `yield`, `()`, `[]` or `===` on the method's own `&block` parameter. A block literal runs in the frame that created it, but the caller may pass a C-function proc: `y(s, &:=~)` yielding `"zz", /(q)/` runs `String#=~` on `y`'s behalf, and `y`'s `$1` then reads `nil`;
  - a statement whose call, or a call in its receiver chain or arguments, carries a block literal whose body may run a match (defined below);
  - a statement whose call, or a call in its receiver chain or arguments, passes a `&expr` block argument that may be a proc created in this body. That is anything but a Symbol literal (unless it names `=~`, `match`, `sub`, `sub!`, `gsub`, `gsub!`, `scan` or `===`), an anonymous `&`, or the method's own `&block` parameter while the body neither rebinds nor shadows it; the last two forward the block the caller created;
  - any call in a body that creates a closure whose body may run a match — a lambda literal, or a block literal passed to a call that may keep it to run after it returns — in the body or in a method's parameter defaults, because the closure can run through any later call; and any call in a body that calls `binding`, because a `Binding#eval` of it runs in this frame wherever it is called. A call may keep its block unless it is named like a core iterator that runs its block only while it runs — the eager `Enumerable`, `Array`, `Hash`, `Range`, `Integer` and `IO` iterators (`each`, `map`, `select`, `each_with_index`, `times`, `each_line`, `foreach`, …), `tap`, `then`, `yield_self`, the block forms of `sub`, `sub!`, `gsub`, `gsub!`, `scan`, `grep` and `grep_v`, `loop`, `catch`, `open`, and `instance_eval`, `class_eval`, `module_eval` and their `_exec` forms — or by the `each_` prefix, and even then a call on a lazy enumerator (a `lazy` call in its receiver chain) keeps it. So `lambda`, `proc`, `Proc.new`, `define_method`, `Hash.new`, `Enumerator.new`, the methods that return an Enumerator holding the block (`chunk_while`, `slice_when`, …), `super`, and a user method may keep it: `on(:x) { |l| l =~ re }` hands a block that a later `emit(:x, t)` runs in this frame. The answer is by name, because the body is read before most receivers are bound; a project method named like a core iterator is read as one, which is a known gap if it keeps its block. The rule covers every call in the body, not only those after the closure, because in a loop a call written before the closure can run after it.

  A block or closure body *may run a match* when it contains one of the following anywhere except inside a nested `def`, class or module body:
  - a call to `=~`, `match`, `sub`, `sub!`, `gsub`, `gsub!` or `scan`, which set the globals whatever their argument;
  - a call to `[]`, `slice`, `slice!`, `index`, `rindex`, `partition`, `rpartition` or `split` with an argument known to be a Regexp: a regex literal, a constant bound to one, a local or instance variable bound to one in the scope where the block is written, or `Regexp.new` / `.union` / `.compile`. `grep` and `grep_v` count on the same terms, but only in their block form, since without a block they leave the caller's `$~` alone. Inside a block these names are overwhelmingly Hash, Array and String lookups, so a Regexp that reaches the lookup any other way is not counted. A Regexp that arrives as a block parameter, is assigned inside the block, or comes from a method's return value is a known gap;
  - `===` on a receiver that may be a Regexp;
  - a `when` condition of a `case` with a subject, or a value in an `in` / `=>` pattern, that may be a Regexp: a regex literal, a pinned or other non-constant expression, a constant bound to a Regexp, or a splat of a constant holding one. These do not count: a literal that is not a Regexp; a constant bound to anything else (a class or module, a collection, any other value); and a constant that does not resolve, which is read as a class. A Regexp constant defined in another file currently does not resolve, because the cross-file constant census does not publish a Regexp literal, so it is not counted; that gap is tracked in [#1373](https://github.com/rigortype/rigor/issues/1373). A `case` without a subject runs no `===`, and a pattern's `if` / `unless` guard is ordinary code, scanned like the rest of the body;
  - a bare regex condition, a write to `$~`, a `yield`, a call that the implicit-self and `&block` rules above count (`eval(src)`, `send(name, x)`, `blk.call(x)`, …), or a `&expr` block argument as above.

  A Symbol block argument naming a lookup (`&:[]`, `&:index`) whose elements pass a Regexp argument rebinds the globals as well; it is not counted, a known gap that is rare in practice.

  Some calls that reach the slot are not recognised yet: a C-implemented method outside the match-capable names that matches (`start_with?(re)` on an explicit receiver, or a native extension's method), an explicit-receiver `send` or String-form `instance_eval` / `class_eval` / `module_eval`, and a match-capable call in an operand of any other call or construct (`out << line.sub(re, "")`, `[s.index(re)]`), which are tracked in [#1365](https://github.com/rigortype/rigor/issues/1365); `super` into a C-implemented match method (`def sub(*) = super` in a `String` subclass); and a C-function proc called through anything but the method's own `&block` parameter (`m = :=~.to_proc; m.call(s, re)`).

  A block body that may run a match, or any block body in a body that creates such a closure, does not read the narrowing from outside the block, because it can run after an earlier iteration rebound the globals. Any other block body reads the outer narrowing, with these known exceptions that are not modelled yet:
  - the block of `gsub`, `gsub!`, `sub`, `sub!`, `scan`, `grep` or `grep_v`, which runs after the call has set `$~` to its own match, and a lambda or proc body, which runs when it is called, not where it is written ([#1371](https://github.com/rigortype/rigor/issues/1371));
  - the root block of `Thread.new` or `Fiber.new`, which gets a fresh slot ([#1361](https://github.com/rigortype/rigor/issues/1361)).

  Separately from blocks, a regex `when` arm or `in` pattern that fails leaves `$~` nil after the `case`, which the narrowing does not model yet ([#1372](https://github.com/rigortype/rigor/issues/1372)).

  A later successful `Regexp.last_match` consult observes the same proven-match bindings rather than re-deriving them.

## Fact stability and mutation

Flow facts are valid only while the analyzer can trust the path they describe. Rigor MUST invalidate or weaken facts when Ruby behavior can mutate, replace, or escape the observed target.

Facts MUST carry a target and a stability reason. The first implementation distinguishes at least:

- **local binding facts**, such as "local `x` currently refers to a non-nil value";
- **captured local facts**, where a block, proc, or lambda may write the local from another lexical scope;
- **object-content facts**, such as hash keys, instance variables, singleton methods, and object-shape members;
- **global storage facts**, such as constants, class variables, and globals (the regex match globals are frame-local instead; see § "Regexp match-predicate narrowing");
- **dynamic-origin and relational facts**, which may survive local calls but still need target invalidation.

### Targeted invalidation

Local binding facts are stable across ordinary method calls until assignment to that local. A call MAY mutate the object referenced by the local, but it MUST NOT rebind the local variable itself unless the local is captured by a closure that writes it. Therefore:

- `x.is_a?(String)` remains a local binding fact after an unknown call that cannot write `x`;
- `x[:key]` or `x.foo` shape facts MAY be weakened by a call that can mutate `x` or escape it;
- facts about instance variables, class variables, globals, and constants are heap or global-storage facts and are invalidated more aggressively.

Unknown method calls remain conservative for heap facts. They MAY invalidate object-shape, hash-entry, instance-variable, constant-object, and global-storage facts for any target that may have escaped to the call. They MUST NOT invalidate every local binding fact in the current scope.

### Closure captures

Closure-captured locals need explicit handling. When a block, proc, or lambda writes an outer local, Rigor MUST record a captured-local write effect. If the closure is invoked immediately and its body is available, Rigor applies the write at the call edge. If the closure escapes or may be invoked later, facts about locals it can write become unstable after the escape point and before any unknown invocation of that closure.

### Block call timing

Block and higher-order method calls SHOULD be modeled through call-timing and mutation effects instead of a blanket "yield invalidates everything" rule. Useful first categories are:

- no block invocation;
- immediate non-escaping invocation, once or a known bounded number of times;
- immediate non-escaping invocation, unknown number of times;
- deferred or escaping block storage;
- unknown block behavior.

Known Ruby methods such as `tap`, `then`, `yield_self`, and `each_with_object` SHOULD eventually receive summaries for block timing, return behavior, and receiver or argument mutation. Without such a summary, Rigor MAY be conservative for object-content facts, but it SHOULD still preserve unrelated local-binding facts.

The first summary shipped is the return-type one for **immediate, exactly-once** yielders: `Kernel#tap`, `Kernel#then`, and `Kernel#yield_self` call their block once, before returning, on every path ([#1095](https://github.com/rigortype/rigor/issues/1095)). When such a call carries a literal block whose normal completion is unreachable, the callee's own result is unreachable too, and the call's type MUST be the union of its `break` arms alone, or `bot` when there are none:

```ruby
[1, 2].tap { break "s" }         # "s"            (not "s" | Array)
[1, 2].tap { raise "x" }         # bot            (not Array)
[1, 2].tap { break "s" if cond } # "s" | Array    (the block can complete)
[1, 2].tap { next "s" }          # Array          (`next` completes the block)
[1, 2].each { break "s" }        # "s" | Array    (`each` may never yield)
```

Unreachable normal completion MUST be established by two proofs that both hold. The first is syntactic: every path through the block body ends in a block-level `break`, `return`, `redo`, or `retry`, or in a receiver-less, `self.`, or `Kernel.` call to `raise`, `fail`, `throw`, `exit`, `exit!`, or `abort` that no project code defines under that name (a top-level `def`, a method on any class or module on either side, or a `pre_eval:` patch all disqualify it), or in an expression that must evaluate one of those first. Only unconditionally evaluated positions count: a nested block, lambda, `def`, or loop is not entered, `&&` / `||` count only their left operand, an `if` / ternary needs both arms, a `begin` with `rescue` needs its body and every rescue clause to exit, and an `ensure` that must exit qualifies on its own. The second is the block-return pass typing the block as exactly `bot`, so a reachable `next` (which completes the block) keeps the union. A `bot` from the block-return pass is not enough alone: it also arises when the block's last call merely declares a `bot` return, which a project signature can do, and which `Kernel#loop` did before the widening below. A shape the syntactic walk does not recognise keeps the union.

The rule is gated on the declaration the call resolves to, not on the method name: the declaring owner MUST be `Kernel`, the owner in both CRuby and the core RBS. A receiver whose class, a project ancestor, or a project signature defines its own `tap` / `then` / `yield_self`, a top-level `def` of the name, a project patch on `Object` / `Kernel` or on any RBS ancestor of the receiver's class (a reopened `Enumerable`, and `Module` / `Class` for a class-object receiver), a receiver that names no class (`Dynamic`, `top`), and a project class whose ancestry leaves the project through a class no signature describes all keep the `break | normal-return` union. A block-pass (`&blk`, `&:sym`) carries no body to prove anything about and keeps the union as well. A block value that is `nil`-bearing or `Dynamic` rather than exactly `bot` does not trigger the rule. For `then` / `yield_self` the rule restates what type-variable binding already produces (their RBS return is the block's type, so `T := bot`); `tap` is the method it changes, because its `-> self` return never mentions the block.

#### `Kernel#loop` completes on `StopIteration`

`Kernel#loop` is declared `() { () -> void } -> bot` in core RBS, but it rescues a `StopIteration` its block raises and returns that exception's `result`, so the enumerator-draining idiom `loop { out << e.next }` returns normally (with `e`'s own `each` value) once `e` is drained ([#1107](https://github.com/rigortype/rigor/issues/1107)). A receiver-less, `self.`, `Kernel.`, or `::Kernel.` call of `loop` whose dispatch answers `bot` MUST therefore be typed `untyped` (`StopIteration#result`'s declared type) for its normal completion, and `break` arms MUST be unioned with it as usual. The declared `bot` MUST be kept only when the block declares no parameters and its body provably cannot raise. Every node in the body must then be one of: an integer, float, rational, or imaginary literal; a string or symbol literal without interpolation; `nil`, `true`, `false`, or `self`; a local or instance-variable read or plain write; an array literal without a splat; `if` / `unless` / `else` / `&&` / `||`; parentheses; or `break` / `next` / `redo` / `return` with such arguments. Everything else widens, including regexp, range, and hash literals, `__FILE__` and friends, constant reads, operator-assignments (`x += 1`), any call (operators and `[]` included), `yield`, `super`, splats, interpolation, and `rescue`. `raise` is a call too, and the walk does not tell `raise "x"` apart from `raise StopIteration`. A declared block parameter widens because its default (`|v = e.next|`) runs on every iteration. A block-pass (`loop(&blk)`) has no body to inspect and widens too.

```ruby
loop { e.next }                 # untyped         (not bot)
loop { break 1 if e.next == 2 } # 1 | untyped     (the drain ends it too)
loop { break 5 }                # 5               (the body cannot raise)
loop {}                         # bot
def drain(e) = loop { e.next }  # returns untyped (not bot)
```

An explicit receiver (`obj.loop { ... }`) cannot reach the private `Kernel#loop`, so its declared type is kept. The blockless `loop` is an `Enumerator` and is not affected. The `tap` rule's syntactic walk above does not treat `loop` as non-returning either, so it stays a second guard for the same idiom.

The catalogue is built in, like the closure-escape catalogue, and names `(owner, method)` pairs so an `RBS::Extended` call-timing effect ([rbs-extended.md](rbs-extended.md)) can replace it without changing the rule. Mutation and fact-retention uses of the same timing fact are not covered by it.

### Proof obligations for stronger fact retention

The first implementation can use these proof obligations for stronger fact retention:

- a local binding has not been assigned and is not writable by an escaping closure;
- the value is an immutable singleton or immediate value, such as `nil`, `true`, `false`, a symbol, or an integer;
- the value is proven frozen for the relevant operation;
- the value is freshly allocated, has not escaped, and has not been passed to a call that may mutate or store it;
- a RBS, `RBS::Extended`, or plugin effect declares that the call is read-only, pure for the relevant target, or mutates only specific receivers or arguments.

Plugins MAY return explicit mutation, escape, call-timing, purity, or invalidation effects rather than mutating `Scope` directly. The bundle schema is in [rbs-extended.md](rbs-extended.md).

## Scope snapshots and fact buckets

The first implementation pairs a category-bucketed fact store with immutable per-edge `Scope` snapshots:

- Each `Scope` is an immutable snapshot keyed by control-flow edge. Joins, narrowing, and invalidation produce new snapshots through structural sharing rather than in-place mutation.
- Within a snapshot, facts are partitioned into buckets that mirror the categories above: local-binding, captured-local, object-content, global-storage, dynamic-origin, and relational. Invalidation rules act on a specific bucket, so an unknown method call sweeps object-content while leaving local-binding intact.
- Relational facts that span multiple targets live in their own bucket and are invalidated when any participating target's bucket records a change.
- The public surface of `Scope` MUST NOT expose buckets directly. Plugins, narrowing rules, and diagnostics ask `Scope` for facts about a target; the bucket layout is an internal optimization that MAY evolve.

## Purity policy

The pre-plugin purity policy controls how method-call results are remembered or forgotten across re-invocations:

- Methods are treated as **impure by default**. Calling an impure method on a receiver invalidates the receiver's object-content bucket and discards remembered value facts for prior calls to the same receiver.
- Purity becomes effective only when an authoritative source declares it: core Ruby and stdlib RBS distributed with Rigor, accepted ordinary RBS files, or explicit `%a{pure}` annotations on `RBS::Extended`. Generated signatures and plugin contributions MAY refine purity within their tier. The purity annotation is `%a{pure}` — the ecosystem's existing spelling, read as the empty effect envelope tolerating `mutate.local` ([effect-labels.md](effect-labels.md)). `rigor:v1:pure` was the spelling this section originally named; it was never implemented and is dropped in favour of `%a{pure}` ([ADR-103](../adr/103-effect-labels.md) WD14).
- A configuration switch makes the default look more like PHPStan's "value-returning is pure unless declared impure" policy for projects that want stronger narrowing across repeated calls. The switch flips the default but never overrides explicit `pure` or mutation declarations.
- `pure` combined with any receiver-mutation, argument-mutation, or fact-invalidation effect is a contract conflict, as specified in [rbs-extended.md](rbs-extended.md).

## Built-in mutation summaries

The first user-visible milestone (v1) ships built-in mutation, purity, and call-timing summaries for a fixed set of core and stdlib classes. The covered set is `Array`, `Hash`, `String`, `Set`, `IO`, `StringIO`, `File`, `Tempfile`, `Pathname`, and `Logger`. Each summary records:

- per-method receiver-mutation status, argument-mutation status, and fact-invalidation effect;
- per-method block call timing using the categories above;
- per-method purity declaration where it can be made without overpromising.

Classes outside this set follow the impure-by-default policy until ordinary RBS, `RBS::Extended`, or plugin facts say otherwise. Rigor MUST NOT silently assume purity or mutation behavior for them.

The deferred roadmap extends coverage to additional core classes (`Numeric` and its descendants, `Symbol`, `Range`, `Regexp`, `Proc`, `Method`, `Time`, `Date`, `DateTime`), broadly used stdlib (`Date`, `JSON`, `URI`, `OpenStruct`, `Forwardable`, `Comparable`-bearing classes that need explicit mutation summaries), and selected metaprogramming-adjacent core APIs (`Module`, `Class`, `BasicObject`). Each addition lands incrementally so previously shipped behavior is not perturbed as the larger surface lands.

Built-in mutation summaries are not a closed list. New entries MAY be added in any minor release as long as their addition does not change the meaning of code that does not call them; the published roadmap is a planning aid, not a contract.

## Pre-plugin narrowing surface

The pre-plugin narrowing surface is the set of facts Rigor produces in heavily `Dynamic[top]` code before any user plugin is loaded.

This specification describes the full pre-plugin surface that the analyzer ultimately supports. The first user-visible product release (v1) is a scoped slice of that surface; it does not redefine the spec. Internal data structures such as fact buckets, the capability-role catalog, and built-in mutation summaries are normative from v1; the *derivation rules* exposed to users are tightened in v1 and broaden across later releases.

### v1 narrowing surface

- Literal narrowing for `nil`, `true`, `false`, integer and string literals, and finite literal-union refinements produced by equality checks against trusted built-in domains.
- Syntax-level guards: `is_a?`, `kind_of?`, `instance_of?`, `nil?`, truthiness, `respond_to?`, equality with literal sets, and class- or pattern-matching narrowing in `case` and `case/in` forms that do not require dataflow across statements.
- Method-call resolution that uses RBS or `RBS::Extended` for core Ruby and a curated subset of stdlib without requiring user plugins. Generated signatures from `RBS::Extended` MAY participate.
- Direct application of the bundled core/stdlib mutation summaries at call sites where the receiver is statically known. Summaries drive bucket invalidation locally.
- Intra-procedural propagation of narrowing facts across straight-line code, branch joins, and loop bodies (shipped across the `0.1.x` line). Concrete mechanisms: read-before-write `nil` contribution, intervening- / mutating-call fact invalidation, `retry`-edge widening, `receiver[key] ||= default` indexed narrowing, single-hop method-chain narrowing (`x.last` after `if x.last.is_a?(Array)`), and instance-variable guard narrowing (`return if @ivar.nil?`).
- Plugin-supplied flow contributions via `FlowContribution` — a plugin's `truthy_facts` / `falsey_facts` / `post_return_facts` flow through the narrowing engine (ADR-9, v0.1.1+).

### Deferred

- capability-role *requirement inference* from method bodies (the catalog and explicit `conforms-to` directives are already available; deriving "what role does this body require" is deferred);
- full cross-statement propagation of *mutation effects* (as distinct from the narrowing-fact propagation above), beyond the local bucket-invalidation cases.

Each deferred surface ships incrementally so the shipped behavior stays stable while the larger surface lands.

## Version-guard condition folding

A **version guard** is an `if` / `unless` predicate that compares the running Ruby — or a version constant Rigor can read — against a literal, to select between API generations. Multi-version libraries carry the shape routinely:

```ruby
if Gem::Version.new(Psych::VERSION) >= Gem::Version.new("3.1.0.pre1")
  ::YAML.safe_load(yaml, permitted_classes: permitted_classes)
else
  ::YAML.safe_load(yaml, permitted_classes)   # the Psych < 3.1 positional form
end
```

When both sides of such a comparison are decidable, Rigor MUST fold the guard and treat the arm that cannot run as **unreachable**: the arm MUST NOT produce diagnostics, and its bindings MUST NOT join into the post-`if` scope — exactly the treatment `if false` already receives. Rigor MUST NOT report `flow.always-truthy-condition` (or any other redundant-condition diagnostic) on the guard itself: a version guard is intentional, and reporting it would fire on correct code.

The reference values are read from the Ruby running the analyzer, the same premise under which `RUBY_VERSION` is refined and core/stdlib RBS is loaded. The foldable set is deliberately closed:

- `RUBY_VERSION <cmp> "x.y.z"` for `<`, `<=`, `>`, `>=`, `==`, `!=`. The comparison MUST use **String** semantics, because that is what runs — Ruby compares strings lexically, so `RUBY_VERSION >= "3.10"` is false on 3.9 and Rigor MUST reproduce that rather than an idealised version ordering.
- `Gem::Version.new(a) <cmp> Gem::Version.new(b)`, with both sides wrapped, compared with `Gem::Version` semantics. A *mixed* comparison (one side wrapped, the other a bare String) MUST NOT fold: `Gem::Version#<=>` answers nil for a non-`Gem::Version` operand, so the comparison raises at runtime and no arm is live.
- `RUBY_ENGINE == / != "…"`. Ordering comparisons on an engine name are not version guards and MUST NOT fold.
- `X::VERSION`, only for constants belonging to a **default gem of the running Ruby**. A gem whose version the project resolves through its own `Gemfile.lock` MUST NOT be read from the analyzer's runtime, because the two copies can differ.

A **rooted** spelling names the same constant its bare twin does — `::` only makes the top-level lookup explicit — so `::RUBY_VERSION`, `::RUBY_ENGINE` and `::X::VERSION` MUST fold exactly as `RUBY_VERSION`, `RUBY_ENGINE` and `X::VERSION` do. This widens no set: a rooted name outside the sets above is as unfoldable as the bare one.

Everything else keeps both arms live, which is always the safe answer: `<=>` (it yields an ordering, not a verdict), `RUBY_PLATFORM` (every comparison against it is platform-dependent by construction, and the checking machine need not be the running machine), `defined?`-style capability probes, `!` / `&&` / `||` compositions, `case` subjects, and a comparison between two bare String literals (a constant comparison, not a version guard). A guard with an unreadable operand is undecidable and both of its arms MUST stay live.

Rationale and the false-positive argument: [ADR-47](../adr/47-narrowing-driven-clause-reachability.md) § WD5.

## Diagnostics

Diagnostics that arise from control-flow analysis live primarily in the `flow.*` family. Strict modes that depend on dynamic-origin provenance live in the `dynamic.*` family. Cutoff diagnostics live in `static.*`. The full identifier taxonomy is in [diagnostic-policy.md](diagnostic-policy.md).
