# Dynamic-fall pattern survey (post-ADR-55/56)

2026-06-12. Read-only engine-behaviour survey. **No `lib/` changes.**

## Methodology

A probe corpus of 139 `dump_type(...)` shapes across 11 `/tmp/probe_*.rb`
files (consolidated copy: `/tmp/probe_consolidated.rb`) was run through
`nix … develop --command bundle exec exe/rigor check --no-cache <file>`,
each shape's inferred type read off the `info: dump_type:` line. Shapes
span recursion, Enumerable chains, accumulator idioms, numeric, string,
Hash/Array structure, control flow, and cross-def composition — with
class-method and toplevel-def variants where the dispatch path might
differ. Non-constant Integer sources use `def some_int = [1,2,3].sample`
to dodge the "constant-arg value-pinning" path and exercise the engine's
*real* generic capability. ADR-55 (recursive returns) and ADR-56
(block-captured write-back / loop fixpoint) just landed; shapes those
fixed (factorial/string-builder recursion, `reduce(:sym)`, `while`-loop
accumulator existence, `each`-block write-back of the *accumulator
variable*) are confirmed working and excluded from the gap inventory —
the focus is what is **next**.

## Summary table

| Bucket | Representative | Verdict | Radius | Difficulty |
| --- | --- | --- | --- | --- |
| **B1. `<<`/`push` element-type drop in block/loop write-back** | `out=[0]; [1,2,3].each{\|x\| out<<x}; out` → `Array[0]` (really `[0,1,2,3]`) | **WRONG (unsound)** | very high | mechanism |
| B2. Toplevel/class-method non-constant param → Dynamic | `def double(x)=x*2; double(some_int)` → `Dynamic[top]` | DYNAMIC | very high | mechanism |
| B3. `each_with_object` return not adopting mutated memo | `arr.each_with_object([]){…}` → `Dynamic[top]` | DYNAMIC | high | mechanism |
| B4. Block/loop-built collection element type lost | `out=[]; arr.each{\|x\| out<<x*2}; out` → `Array[Dynamic[top]]` | IMPRECISE-SOUND | high | mechanism |
| B5. `Array#to_h { block }` pair type lost | `[1,2,3].to_h{\|x\| [x,x*2]}` → `Hash[Dynamic[top],Dynamic[top]]` | IMPRECISE-SOUND | medium | catalog/mechanism |
| B6. `flatten` element type lost | `[[1,2],[3,4]].flatten` → `Array[Dynamic[top]]` | IMPRECISE-SOUND | medium | catalog |
| B7. Lambda/proc body args not value-pinned | `->(x){x*x}.call(3)` → `Dynamic[top]` | DYNAMIC | medium | mechanism |
| B8. `case/in` deconstruct bindings → Dynamic | `case x in [a,b] then a+b` — `a` → `Dynamic[top]` | IMPRECISE-SOUND | medium | mechanism |
| B9. `Hash.new(default/&block)` read → bare/Dynamic | `Hash.new(0)` → `Hash`; `Hash.new{…}; h[k]` → `Dynamic[top]` | IMPRECISE-SOUND | medium | catalog |
| B10. Multi-call / build / mutual recursion → Dynamic | `fib(n)` → `1 \| Dynamic[top]`; `tree_sum`, `srev`, `even?` → `Dynamic[top]` | IMPRECISE/DYNAMIC | low-med | mechanism |
| B11. `chunk_while.to_a` / lazy-enumerator chains | `arr.chunk_while{…}.to_a` → `Array[Dynamic[top]]` | IMPRECISE-SOUND | low | catalog |

Everything else probed is **PRECISE** or acceptably IMPRECISE-SOUND with
value loss only (e.g. `split.join` → `literal-string`, `gsub`-with-block
→ `String`, `rescue` value join `5?`, `merge` block form, `dig`, `fetch`
with default/block, destructuring `a,b = [1,"x"]`, `transform_values`,
`then`/`tap`, `divmod`, bit-ops, `step`/`fdiv` unions). `find` over a
constant tuple returns the constant-folded found element (`nil` / `2`) —
**sound**, it is per-element block evaluation, not a dropped-nil bug.

## Per-bucket detail

### B1 — `<<` / `push` element drop in write-back (UNSOUND — top priority)

ADR-56 slice A made the accumulator *variable* survive a block/loop
write-back, but the appended element's type is **not joined into the
array's element parameter**. With a non-empty seed the result is an
unsound under-approximation:

```ruby
def b1
  out = [0]
  [1,2,3].each { |x| out << x }   # really becomes [0,1,2,3]
  out
end
dump_type(b1)            # Array[0]      <-- WRONG (should be Array[0|1|2|3])
dump_type(b1.first)      # 0             <-- WRONG
x = b1.first
dump_type(x.zero?)       # true          <-- concrete wrong fold
```

`x.zero? → true` is a hard wrong constant fold: at runtime `x` ranges
over `0|1|2|3`. A downstream `if x.zero?` / `x == 0` would be
mis-analysed (spurious `always-truthy`, dead-clause risk under ADR-47).
With an *empty* seed (`out=[]`) the drop instead degrades to a sound
`Array[Dynamic[top]]` (B4) — so the unsoundness is specifically the
non-empty-seed path retaining only the seed element type while ignoring
appended ones. Anchor: the ADR-56 write-back path
(`lib/rigor/inference/...` block-captured-local mutation) widens the
binding but does not union the `<<`/`push` argument type into the
receiver array's element. **Fix is NOT precision-additive** — it removes
an unsound result, so it must land with the join, not a widen-to-Dynamic
shortcut (though widening the seed array to `Array[Dynamic[top]]` on any
appended write is the cheap *sound* stopgap).

### B2 — non-constant param → Dynamic (highest radius gap)

```ruby
def double(x) = x * 2
dump_type(double(some_int))        # Dynamic[top]
def trip(x) = x * 3
dump_type(trip(4))                 # 12   <-- constant arg DOES pin
class Calc; def self.double(x)=x*2; end
dump_type(Calc.double(some_int))   # Dynamic[top]   (class method no better)
def greet(name:, greeting:"hi")="#{greeting} #{name}"
dump_type(greet(name:"x"))         # Dynamic[top]   (kwargs too)
```

Constant-literal args value-pin (`trip(4)→12`), but a non-constant arg
leaves the parameter `Dynamic[top]`, contaminating the whole body. This
is the single most common real-Ruby shape (every helper called with a
computed value). The ADR-24 adoption gate territory: bodies *are*
analysed, but with `Dynamic` params. A signature-inference / per-call
arg-type adoption pass (analyse the body against the *actual* call-site
arg type, à la a localised contextual typing) is the mechanism. Highest
blast radius in the survey; hardest single item.

### B3 — `each_with_object` return drop

```ruby
arr.each_with_object({}) { |x, h| h[x] = x*2 }   # Dynamic[top]
arr.each_with_object([]) { |x, acc| acc << x*2 } # Dynamic[top]
```

`iterator_dispatch.rb:130 each_with_object_block_params` threads the
memo into the *block params*, but the dispatch returns `Dynamic[top]`
rather than the (mutated) memo type. This is the canonical "build a hash
in one expression" idiom — very high radius. Even returning the memo's
*entry* type (`{}`→`Hash[…]`, `[]`→`Array[…]`) unmodified would beat
`Dynamic`; full precision needs the same element/pair join as B1/B4.

### B4 — block/loop-built collection element type (sound, high radius)

```ruby
out=[]; [1,2,3].each { |x| out << x*2 }; out   # Array[Dynamic[top]]
def countdown(n); acc=[]; while n>0; acc<<n; n-=1; end; acc; end
dump_type(countdown(some_int))                 # Array[Dynamic[top]] | []
```

Sibling of B1/B3 from the empty-seed side — sound but element-blind. The
loop *existence* works (ADR-56) but the element type is `Dynamic`. Same
fix lever as B1 (join append types into the element param); shipping B1
soundly should subsume this.

### B5 — `Array#to_h { block }`

```ruby
[1,2,3].to_h { |x| [x, x*2] }        # Hash[Dynamic[top], Dynamic[top]]
arr.to_h { |x| [x, x*2] }            # Hash[Dynamic[top], Dynamic[top]]
```

`shape_dispatch.rb:87` only folds `to_h` on a *tuple* receiver
(`tuple_to_h`) and on Data; `Array#to_h` with a pair-producing block has
no fold, so it hits the RBS generic and the block's `[K,V]` return is
not substituted. Medium radius (config/lookup-table building).

### B6 — `flatten`

```ruby
[[1,2],[3,4]].flatten     # Array[Dynamic[top]]   (ideal [1,2,3,4])
[1,[2,[3]]].flatten       # Array[Dynamic[top]]
[[1,2],[3,4]].flatten(1)  # Array[Dynamic[top]]
```

`flatten` (non-bang) has no tuple/shape fold — `array_catalog.rb:23`
lists only `flatten!`. Even a one-level flatten of a literal-of-literals
loses everything. Pure catalog/shape gap; for a tuple-of-tuples the
result is computable exactly.

### B7 — lambda/proc args not value-pinned

```ruby
->(x) { x*x }.call(3)            # Dynamic[top]   (def trip(3) would pin)
sq = ->(x){x*x}; sq.call(3)      # Dynamic[top]
proc { |x| x+1 }.call(3)         # Dynamic[top]
```

Distinct from B2: a `def` value-pins a *constant* arg (`trip(4)→12`) but
a lambda/proc body does **not**, even with a constant. Block-body
parameter typing from `call`-site args is unimplemented. Medium radius.

### B8 — `case/in` deconstruct bindings

```ruby
case x
in [a, b] then a + b      # a, b → Dynamic[top]
in Integer => n then n    # n narrows fine
else 0
end
# classify([1,2]) → 0 | Dynamic[top] | Integer
```

`in Integer => n` binds precisely; array/find-pattern element bindings
(`[a, b]`) type `Dynamic[top]` even when the subject is a known tuple.
The deconstruction projection that `data_instance`/`shape_dispatch`
already do for Data/HashShape is not wired into the pattern-binding path
(`statement_evaluator.rb` pattern handling).

### B9 — `Hash.new` default

```ruby
Hash.new(0)                                  # Hash    (bare, no value type)
h = Hash.new { |hh,k| hh[k]=k*2 }; h[k]      # Dynamic[top]
def counter; h=Hash.new(0); h[:x]+=1; h; end # Hash; counter[:x] → Dynamic[top]
```

`Hash.new(default)` types as bare `Hash` (default value type not lifted
into the value param); the block form's `[]` read is `Dynamic`. The
`Hash.new(0)` counter idiom is extremely common; catalog work to model
the default-arg / default-block value type.

### B10 — recursion not covered by ADR-55

ADR-55 fixed single-call value-building recursion. Still falling:

```ruby
def fib(n)=n<2 ? n : fib(n-1)+fib(n-2)        # 1 | Dynamic[top]   (two calls)
def tree_sum(n); return n if n.is_a?(Integer); n.sum{|c| tree_sum(c)}; end # Dynamic[top]
def srev(s)=s.empty? ? s : srev(s[1..])+s[0]  # Dynamic[top]      (string concat recursion)
def even?(n)=n==0 ? true : odd?(n-1)          # Dynamic[top]      (mutual)
def hanoi(...); moves<<[from,to]; moves; end  # Array[Dynamic[top]]
```

`gcd`/`ackermann` → `Integer` (precise — `Integer#%`/`+` absorb the
in-cycle `Dynamic`). The fixpoint summary doesn't converge for: two
self-calls in one expression (`fib`), `+`-built String recursion
(`srev` — string concat doesn't absorb Dynamic the way `Integer#*`
does), mutual recursion (`even?`/`odd?` — the ADR-24 key is per
`(receiver,method)`, mutual pair re-enters as Dynamic), and accumulator
recursion through `<<` (`hanoi` — compounds with B1). Lower radius than
B1-B4; the mutual-recursion and string-builder cases are the most
idiomatic.

### B11 — lazy-enumerator chain tails

`chunk_while{…}.to_a` → `Array[Dynamic[top]]` while `each_slice(2).to_a`
and `each_cons(2).to_a` are precise (`Array[Array[1|2|3]]`). Isolated
`chunk_while`/`chunk`/`slice_when` enumerator `.to_a` coverage gap. Low
radius.

## Recommended attack order

1. **B1 — `<<`/`push` element-type drop (UNSOUND).** The only
   soundness defect found. `Array[0]` for a really-`[0,1,2,3]` array
   yields concrete wrong folds (`x.zero? → true`). Fix by joining
   appended element types into the array element param in the ADR-56
   write-back; the cheap *sound* interim is to widen any written-to
   seed array to `Array[Dynamic[top]]`. Soundness first.
2. **B4 + B3 (element/memo join).** Same lever as B1 from the
   sound-but-imprecise side; shipping B1's join should largely subsume
   B4, and `each_with_object` returning its (joined) memo closes the
   highest-radius *precision* idiom. Do together.
3. **B2 — non-constant param adoption.** Highest blast radius overall;
   biggest mechanism (per-call body re-typing against actual arg types).
   Ranked below B1-B4 only because it is the largest build and
   precision-additive (no soundness pressure).
4. **B6 `flatten` + B5 `Array#to_h{block}` + B9 `Hash.new` default.**
   Catalog/shape-fold gaps, each precision-additive and self-contained;
   high idiom frequency for `Hash.new(0)` and `to_h`.
5. **B8 case/in deconstruct bindings + B7 lambda/proc arg pinning.**
   Reuse existing projection machinery (B8) / extend value-pinning to
   block bodies (B7). Precision-additive.
6. **B10 recursion tail (mutual + string-builder + two-call).** Lowest
   radius; the mutual-recursion key and string-concat fixpoint are the
   worthwhile sub-cases. B11 `chunk_while.to_a` folds in as a one-line
   catalog add.

All of B2-B11 are precision-additive (degrade to today's behaviour). B1
is the lone non-additive item and the lone soundness bug.
