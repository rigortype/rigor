# Website showcase — "this gets a type?!" inference examples (core + plugins)

Status: research note, no design commitments. Candidate inventory for the v0.3.0 launch
website; observations taken against **master @ e5a1acb3** (v0.2.9 + the `[Unreleased]`
section that will ship as v0.3.0).

Every snippet below is taken or lightly adapted from a spec fixture, a plugin `demo/`,
or a shipped doc, with the citation next to it — the inferred type shown is the exact
assertion in the cited spec unless noted. Before publishing any snippet, re-run it
through `rigor type-of` / `rigor annotate` on master so the site shows real tool output
(fixtures assert internal display forms; see "Display conventions" at the end).

## How to use this note

- **Hero candidates** — the handful strong enough to open a landing page.
- **Core engine catalog** — grouped by mechanism, no plugin involved, no annotations.
- **New in v0.3.0** — items that are launch-specific talking points.
- **Plugin catalog** — what the plugin layer adds on top, tiered by wow-factor.
- **Ready-made site material** — examples the docs already present in polished form.

---

## Hero candidates

These four carry the pitch on their own.

### H1. The typo is reported with the *computed value* ([README.md:38](../../README.md))

```ruby
def slug(title) = title.downcase.gsub(/\s+/, "-")

s = slug("Hello World")
s.lenght
# => error: undefined method `lenght' for "hello-verse"… no — for "hello-world"
```

Zero annotations; the diagnostic names the traced value `"hello-world"`, not `String`.
Already framed as "Hello, Rigor" in the README — reuse as the landing-page hero.

### H2. Factorial folds to `120` ([README.md:63](../../README.md), [constant_reduce_fold.rb](../../spec/integration/fixtures/constant_reduce_fold.rb))

```ruby
def factorial(n)        #=> Integer
  (1..n).reduce(1, :*)
end

answer = factorial(5)   #=> 120
```

The unsignatured method types as `Integer`, but the call site folds the whole
computation to the value `120`. Block-form `inject { |acc, i| acc * i }` folds too, and
a 296-bit bignum result gracefully widens back to `Integer`
([constant_reduce_fold.rb:83](../../spec/integration/fixtures/constant_reduce_fold.rb)).

### H3. Recursion is actually unrolled ([recursive_constant_fold.rb:31](../../spec/integration/fixtures/recursive_constant_fold.rb))

```ruby
class Stars
  def render(n) = n <= 0 ? "" : "*" + render(n - 1)
end

Stars.new.render(3)     #=> "***"
Factorial.new.of(5)     #=> 120
Factorial.new.of(100)   #=> Integer   (fuel exhausted → graceful widen)
```

Value-pinned recursion runs to the exact result under a fuel budget; a never-returning
method infers `bot` ([recursive_fixpoint_summary.rb:102](../../spec/integration/fixtures/recursive_fixpoint_summary.rb)).

### H4. Dimensional analysis via plugin ([examples/rigor-units/demo/demo.rb:15](../../examples/rigor-units/demo/demo.rb))

```ruby
distance = 100.kilometers
time     = 2.hours
speed    = distance / time     # inferred: Speed
distance + time                # error: dimensional mismatch: 'Distance + Time'
```

Numeric literals carry physical dimensions; arithmetic composes and validates them
([units_plugin_spec.rb:42](../../spec/integration/examples/units_plugin_spec.rb)). The
single best "the plugin API is this powerful" demo.

---

## Core engine catalog

No plugin, no annotation, in every example.

### Constant folding — the engine executes your expressions

| Snippet | Inferred | Source |
| --- | --- | --- |
| `Math.hypot(3.0, 4.0)` | `5.0` | [math_folding.rb:8](../../spec/integration/fixtures/math_folding.rb) |
| `Math.sqrt(-1)` | `Float` (domain error → declines) | same file |
| `Shellwords.split("git commit -m 'initial commit'")` | `["git", "commit", "-m", "initial commit"]` | [shellwords_folding/demo.rb:16](../../spec/integration/fixtures/shellwords_folding/demo.rb) |
| `CGI.escapeHTML("<b>")` | `"&lt;b&gt;"` | [module_function_folding/demo.rb:28](../../spec/integration/fixtures/module_function_folding/demo.rb) |
| `100.pow(50, 17)` | `4` (modular exponentiation) | [two_arg_fold.rb:36](../../spec/integration/fixtures/two_arg_fold.rb) |
| `"az".succ` / `"ff".hex` | `"ba"` / `255` | [string_array_catalog.rb:38](../../spec/integration/fixtures/string_array_catalog.rb) |
| `123.digits` | `[3, 2, 1]` | [numeric_fold.rb:24](../../spec/integration/fixtures/numeric_fold.rb) |
| `2.5.numerator` / `2.5.denominator` | `5` / `2` | same file |
| `Set[:a, :b, :c] ^ Set[:b, :c, :z]` | `Set[:a, :z]` | [set_constant_folding.rb:23](../../spec/integration/fixtures/set_constant_folding.rb) |
| `format("%05d", 42)` | `"00042"` | [kernel_functions.rb:58](../../spec/integration/fixtures/kernel_functions.rb) |

Website angle: "Rigor evaluates the parts of your program it can prove" — shell
quoting, HTML escaping, and modular exponentiation at type-check time, declining
cleanly (domain errors, bignums, user redefinition of `format` — the ownership gate)
where it can't.

### Tuples, hash shapes, and value objects

```ruby
xs = [10, 20, 30]
xs.rotate(2)            #=> [30, 10, 20]
xs.minmax               #=> [10, 30]
[1, 2, 2, 3].uniq       #=> [1, 2, 3]
```
[tuple_access.rb:8](../../spec/integration/fixtures/tuple_access.rb) — per-position
precision where other checkers hold `Array[Integer]` at best.

```ruby
q, r = 11.divmod(4)     # q => 2, r => 3   (and -7.divmod(3) #=> [-3, 2])
```
[divmod_tuple.rb:13](../../spec/integration/fixtures/divmod_tuple.rb) — floored-division
sign semantics, threaded through destructuring.

```ruby
h = { 1 => 1, 1 => 2, 1.0 => 3, 1.00 => 4 }   #=> { 1 => 2, 1.0 => 4 }
h[1]    #=> 2
h[1.0]  #=> 4      # 1 and 1.0 are distinct keys, exactly as in Ruby
```
[hash_scalar_keys.rb:10](../../spec/integration/fixtures/hash_scalar_keys.rb) — models
`Hash#eql?` key identity and last-wins duplicates (new HashShape coverage in v0.3.0).

```ruby
Point = Data.define(:x, :y)
p = Point.new(1, "two")
p.x               #=> 1
p.with(x: 99).x   #=> 99
```
[data_folding_spec.rb:49](../../spec/rigor/inference/method_dispatcher/data_folding_spec.rb)
— full value semantics for modern immutable records; `Struct` setters re-type the
binding instead of going stale
([struct_catalog.rb:53](../../spec/integration/fixtures/struct_catalog.rb)).

```ruby
config = { host: "example.com", port: 8080 }
config.key?(:host)   #=> true    — proven
config.empty?        #=> false   — proven
```
[docs/handbook/04-tuples-and-shapes.md:126](../handbook/04-tuples-and-shapes.md) —
"proven predicate" phrasing reads like magic in a demo.

### Blocks — per-element typing and captured-local write-back

```ruby
[1, "two", :three].map { |x| x.to_s }               #=> ["1", "two", "three"]
[1, 2, 3].filter_map { |n| n.even? ? n.to_s : nil } #=> ["2"]
```
[tuple_map.rb:14](../../spec/integration/fixtures/tuple_map.rb) — the block body is
re-typed once per tuple position, with branch elision on constant predicates.

```ruby
table = {}
[1, 2, 3].each { |x| table[x] = x.to_s }
table   #=> Hash[1 | 2 | 3, "1" | "2" | "3"]
```
[block_captured_writeback.rb](../../spec/integration/fixtures/block_captured_writeback.rb)
— the canonical imperative build-a-hash idiom, captured soundly (ADR-56 BodyFixpoint).

```ruby
[1, 2, 3].inject(0) { |memo, elem| ... }   # memo => 0, elem => 1 | 2 | 3
```
[enumerable_memo.rb:18](../../spec/integration/fixtures/enumerable_memo.rb) — seed type
flows to the block parameter where RBS says `untyped`.

### Flow-sensitive narrowing

```ruby
if @current_journal          # @x : Journal | nil
  @current_journal.save      # Journal — no possible-nil warning
end
```
[ivar_guard_narrowing.rb:26](../../spec/integration/fixtures/ivar_guard_narrowing.rb) —
instance variables narrow too; this exact pattern was 6 false positives in Redmine.
Reads like a real Rails bug fix.

```ruby
case kind
when 1 then v = "a"
when 2 then v = "b"
else raise ArgumentError
end
v   #=> "a" | "b"    — no phantom nil
```
[case_else_terminates_exhaustion.rb:11](../../spec/integration/fixtures/case_else_terminates_exhaustion.rb);
the same recognition works for `x = src or fail_now` where `fail_now` is a *resolved*
always-raising helper
([or_guard_narrowing.rb:26](../../spec/integration/fixtures/or_guard_narrowing.rb)).

```ruby
return unless v&.start_with?("[") && v.end_with?("]")
v   #=> "[x]"    — &. proved v non-nil, so the bare call after && is clean
```
[safe_nav_truthy_narrows_and_rhs.rb:11](../../spec/integration/fixtures/safe_nav_truthy_narrows_and_rhs.rb)

```ruby
until line = read_next   # exits only when the assignment is truthy
end
line   #=> non-nil
```
[loop_exit_assignment_narrowing.rb:13](../../spec/integration/fixtures/loop_exit_assignment_narrowing.rb)

```ruby
params[:f] ||= []
params[:f] << :status    # slot known non-nil, dispatches on Array
```
[indexed_or_narrowing.rb:11](../../spec/integration/fixtures/indexed_or_narrowing.rb) —
hash key-presence narrowing; the six-times-repeated Redmine `as_params` idiom.

```ruby
case m                    # m : Integer
when 1..10   then m       #=> int<1, 10>
when (100..) then m       #=> int<100, max>
end
```
[case_when.rb:22](../../spec/integration/fixtures/case_when.rb); comparisons compose —
`words.size` is `non-negative-int`, and after `if n > 0` it is `positive-int`
([container_size.rb:13](../../spec/integration/fixtures/container_size.rb)).

```ruby
if /(\d+)-(\d+)/ =~ line
  $1   #=> String     — group is unconditional
end
$1 if /x(y)?/ =~ s   #=> String?   — optional group stays nilable
```
[regex_global_narrowing.rb](../../spec/integration/fixtures/regex_global_narrowing.rb)
— the regex AST itself is analyzed to decide per-group nilability. Constant-pattern
`str =~ RE` gets the same treatment in v0.3.0.

```ruby
state == :ready   # narrows a symbol union member-by-member;
                  # the final else is proven to be the remaining constants
```
[docs/handbook/03-narrowing.md:84](../handbook/03-narrowing.md) — exhaustiveness over
symbol unions without enums.

### Soundness under mutation (the honesty demo)

```ruby
return if arr.empty?     # arr : non-empty-array
arr.clear
puts "emptied" if arr.size == 0   # correctly NOT folded to false
```
[non_empty_refinement_mutation_widening.rb:23](../../spec/integration/fixtures/non_empty_refinement_mutation_widening.rb)
— mutators retract flow refinements. Pairs well with the project's
false-positives-first pitch: precision that *withdraws itself* rather than lie.

### Union arithmetic and interprocedural flow

```ruby
a = [1, 2].sample; b = [2, 3].sample
a + b                                            #=> 3 | 4 | 5
[10, 20, 30].sample * 0                          #=> 0
[1,2,3,4,5].sample + [10,20,30,40,50].sample     #=> int<11, 55>
```
[union_arithmetic.rb:23](../../spec/integration/fixtures/union_arithmetic.rb) —
cartesian evaluation with absorption and interval widening past a cardinality cap.

```ruby
def find(n)
  [1, 2, 3].each { |i| return i if i == n }
  nil
end
find(2)   #=> 1 | 2 | 3 | nil
```
[recursive_unroll_clamp.rb](../../spec/integration/fixtures/recursive_unroll_clamp.rb)
— non-local `return` from inside a block reaches the caller.

```ruby
case value
in { name: String => n, age: Integer => a } then [n, a]  # n: String, a: Integer
end
```
[statement_evaluator_spec.rb:2096](../../spec/rigor/inference/statement_evaluator_spec.rb)
— `case/in` pattern captures bind to their matched types.

### `rigor sig-gen` — inference you can keep

```ruby
class Widget
  def n = 42
end
# sig-gen emits:  def n: () -> 42
```
[generator_spec.rb:36](../../spec/rigor/sig_gen/generator_spec.rb) — literal-precise
RBS from unannotated defs; `module_function` renders as `def self?.`. As of v0.3.0
every emitted signature is re-parsed by `rbs` before being written.

---

## New in v0.3.0 (launch talking points)

From the current `[Unreleased]` section — these are *this release's* precision wins:

- **Anchored-regex string refinement** — `if s.match?(/\A\d+\z/)` refines `s` to a
  decimal-integer string, so a following `Integer(s)` is provably safe.
- **`["a", "b"].join("-")` → `"a-b"`** — exact string, not `String`.
- **Scalar-key hash shapes** — `{ 1 => 2, 1.0 => 4 }` (H/catalog above) is new here,
  plus the `flow.duplicate-hash-key` rule for silently-last-wins literals.
- **rbs-inline out of the box** — `#: (Integer) -> String` comment annotations feed
  inference with no config (ADR-93).
- **Constant-pattern match-global narrowing** — `str =~ RE` narrows `$1`/`$~` like a
  literal regex; `$+` nilability is now group-aware.
- **New always-a-bug rules** — `flow.return-in-ensure`, `flow.shadowed-rescue-clause`,
  `call.raise-non-exception`, `static.value-use.void` (bleeding-edge).
- **Struct/Data through setters and block-defined classes** — two more folding cases.
- **Warm-run performance** — cache-hit runs skip engine load entirely; YJIT arms
  itself past an amortization deadline. Useful for a "fast enough to run on save" line.

---

## Plugin catalog

### Tier 1 — precise types out of DSLs and metaprogramming

**rigor-mangrove — Result/Option unwrap resolves the carried type**
([demo](../../plugins/rigor-mangrove/demo/demo.rb), [spec:81](../../spec/integration/plugins/mangrove_plugin_spec.rb))
```ruby
session.token.unwrap!.upcase              # unwrap! : String — typo after it is caught
session.cached_user.unwrap_or("guest").reverse
```
The generic carrier's `type_args[0]` is instantiated at the unwrap site even though
its RBS return is `untyped`. The Enum DSL likewise mints typed variant classes:
`Shape::Circle.new(1.5).inner.floor` types `inner` as `Float`
([enum_demo.rb](../../plugins/rigor-mangrove/demo/enum_demo.rb)).

**rigor-sorbet — `sig` blocks read statically**
([demo:37](../../plugins/rigor-sorbet/demo/demo.rb), [spec:37](../../spec/integration/plugins/sorbet_plugin_spec.rb))
```ruby
sig { returns(Integer) }
def self.default_length = 32
Slug.default_length.even?      # Integer, no sorbet-runtime needed
T.must(T.let(42, T.nilable(Integer))).bit_length   # nil stripped
```
Migration story: your Sorbet sigs keep working under Rigor.

**rigor-dry-struct / rigor-dry-types — schema → cross-file typed readers**
([demo](../../plugins/rigor-dry-struct/demo/demo.rb), [spec:160](../../spec/integration/plugins/dry_struct_plugin_spec.rb))
```ruby
class User < Dry::Struct
  attribute :name,  Types::String
  attribute :admin, Types::Bool
end
# another file:
user.name    # synthesized reader, return type String
```
dry-types alias compositions resolve transitively (`Types::Email =
String.constrained(format: /@/)` → `String`,
[spec:46](../../spec/integration/plugins/dry_types_plugin_spec.rb)).

**rigor-typescript-utility-types — mapped types over hash shapes**
([spec:128](../../spec/integration/plugins/typescript_utility_types_plugin_spec.rb))
```ruby
Partial(Address)    # every key optional     Required(Address)  # all required
Pick / Omit / Readonly …
```
TypeScript's utility-type algebra over Ruby structural types — catnip for the
TS-curious audience.

**examples/rigor-lisp-eval — a plugin that interprets a mini-language**
([spec:27](../../spec/integration/examples/lisp_eval_plugin_spec.rb))
```ruby
Lisp.eval("(+ 3 4)")        #=> Constant<7>
Lisp.eval("(if c 1 2.0)")   #=> Constant<1> | Constant<2.0>
```
Tutorial plugin, but a striking "the plugin API can compute types" demo alongside
rigor-units.

### Tier 2 — schema/DSL-aware validation with did-you-mean diagnostics

All follow the same satisfying shape: read the real project artifact, validate every
call site, suggest the near-miss.

| Plugin | Checks | Signature diagnostic | Source |
| --- | --- | --- | --- |
| **rigor-activerecord** | `find_by`/`where` kwargs vs `db/schema.rb` | `unknown column 'emial' … did you mean :email?` | [spec:103](../../spec/integration/plugins/activerecord_plugin_spec.rb) |
| **rigor-rails-routes** | path-helper existence + arity vs `routes.rb` | `usres_path … did you mean users_path?` | [spec:65](../../spec/integration/plugins/rails_routes_plugin_spec.rb) |
| **rigor-rails-i18n** | `t("...")` keys + lazy `.key` scope + interpolation vars vs locale YAML | missing key / missing `name:` interpolation | [spec:56](../../spec/integration/plugins/rails_i18n_plugin_spec.rb) |
| **rigor-pundit** | `authorize(post, :destory?)` vs the record's inferred policy class | `did you mean destroy?` | [spec:80](../../spec/integration/plugins/pundit_plugin_spec.rb) |
| **rigor-statesman** | `transition_to(:approval)` vs declared states | `did you mean :approved?` | [spec:42](../../spec/integration/plugins/statesman_plugin_spec.rb) |
| **rigor-sidekiq** | `perform_async` args vs the worker's `#perform` arity (schedule-aware) | arity mismatch | [spec:53](../../spec/integration/plugins/sidekiq_plugin_spec.rb) |
| **rigor-factorybot** | `create(:usre, rol: …)` vs factory attrs + model columns | did-you-mean on both | [spec:69](../../spec/integration/plugins/factorybot_plugin_spec.rb) |
| **rigor-actioncable** | `broadcast_to` / `stream_from` vs discovered channels | near-match hint | [spec:79](../../spec/integration/plugins/actioncable_plugin_spec.rb) |

The Rails cluster (routes + i18n + pundit + AR + factorybot together) makes a strong
"Rigor knows your Rails app" section. Note the ecosystem breadth stat: **30 production
plugins + 6 tutorial examples** on master (counts drift — recount at publish time from
the READMEs, per AGENTS.md).

### Tier 3 — breadth

- **rigor-sinatra** — verb-block DSL macro-expanded; bare `params`/`halt`/`redirect`
  resolve via `Sinatra::Base` ([spec:57](../../spec/integration/plugins/sinatra_plugin_spec.rb)).
- **rigor-hanami** — action protocol (ADR-28): typed `request`/`response`, plus
  `handle-arity-mismatch` ([spec:233](../../spec/integration/plugins/hanami_plugin_spec.rb)).
- **rigor-activesupport-core-ext** — `5.minutes`, `"user_account".camelize`,
  `Array.wrap(nil)`, `nil.blank?` all resolve; without the plugin each is an
  undefined-method ([spec:29](../../spec/integration/plugins/activesupport_core_ext_plugin_spec.rb)).
- **rigor-devise** — `devise :database_authenticatable` synthesizes
  `valid_password?` / `remember_me!` ([consumer](../../plugins/rigor-devise/demo/consumer.rb)).
- **rigor-graphql** — argument/field/enum tables extracted from the class DSL
  ([spec:45](../../spec/integration/plugins/graphql_plugin_spec.rb)).
- **rigor-rbs-inline** — the `#:` / `# @rbs` comment-annotation channel, auto-wired in
  v0.3.0.

---

## Ready-made site material

- **Playground** — [apps/rigor-playground/frontend/index.html:609](../../apps/rigor-playground/frontend/index.html)
  boots with a 15-line sample covering nil-receiver, inline-RBS union mismatch, and a
  greeting fold; live at rigor.typedduck.fail/playground/. Embed it; `rigor trace`'s
  terminal animation ([manual/05](../manual/05-inspecting-types.md)) makes a good
  asciinema/GIF companion.
- **[docs/types.md:19](../types.md)** — the seven-line "carriers at a glance" block is
  the best single "what makes Rigor different" table.
- **[docs/handbook/12-lightweight-hkt.md](../handbook/12-lightweight-hkt.md)** —
  `JSON.parse` typed as the precise recursive sum; the technical-flex example.
- **Credibility numbers** ([docs/CHANGELOG-0.1.x.md:325](../CHANGELOG-0.1.x.md)) —
  Mastodon 789 → 6 diagnostics (−99.2%), Redmine 163 → 79, GitLab FOSS ~670 → ~140.
  Re-validate against v0.3.0 before publishing (the regression-sweep notes have the
  method).
- **Comparison links** — handbook appendices for TypeScript / mypy / Steep / TypeProf /
  Sorbet / PHPStan readers.

## Display conventions (avoid screenshot drift)

Three display forms coexist ([docs/types.md:29](../types.md)): the handbook writes
`Constant<3>`, internal specs `Constant[3]`, and the CLI (`rigor annotate`,
`type-of`) prints the **bare value** (`#=> 120`, `#=> "hello-world"`). Website copy
should use the bare-value CLI form so screenshots and text agree — the tables above
use it already, except where a spec's exact assertion string mattered.

## Suggested next steps

1. Pick the hero set (H1–H4) and ~10 supporting examples per audience page
   (plain-Ruby precision / Rails / migration-from-Sorbet).
2. Run each chosen snippet through `rigor annotate` on master and capture real output.
3. Re-run one credibility sweep (Mastodon or Redmine) on v0.3.0 to refresh the
   false-positive numbers before quoting them.
