# Census-walk gaps — sizing three shapes before fixing any of them (#693)

Status: measurement note. [#693](https://github.com/rigortype/rigor/issues/693) asks
for the shapes to be sized before they are implemented, and this is that sizing. The
conclusion is a **decline**; the only design commitment below is the one recorded
under "Decision".

- Date: 2026-09-09
- Tree: `master` at `5ad2f450`, Ruby 4.0.5 through the Flake
- Instrument: [`tool/probe-693/`](../../tool/probe-693/README.md), raw rows in
  `tool/probe-693/results-20260909.json`

## The three shapes, reproduced

`ScopeIndexer` runs pre-passes that record where each ivar / cvar is written so a
read elsewhere in the class can be seeded. Three write positions never reach a read.
All three answer `Dynamic[top]` on master, against controls that answer precisely:

```ruby
class Control                              # controls
  @@def_klass = nil
  def store = (@@def_klass = Post)
  def read_def_cvar = dump_type(@@def_klass)   # singleton(Post)
  def initialize = (@post = Post.new)
  def read_post = dump_type(@post)             # Post
end

class Census                               # A — class-body cvar
  @@body_klass = Post
  def read = dump_type(@@body_klass)           # Dynamic[top]
end

class Compact                              # B — `class << self`
  class << self
    def configure = (@cfg = Post.new)
    def read_cfg = dump_type(@cfg)             # Dynamic[top]
  end
end

class SelfDef                              # B — `def self.x`, the same mechanism
  def self.configure = (@cfg2 = Post.new)
  def self.read_cfg2 = dump_type(@cfg2)        # Dynamic[top]
end

Widget = Class.new do                      # C — anonymous class body
  def initialize = (@thing = Post.new)
  def thing = dump_type(@thing)                # Dynamic[top]
end
```

The issue names two shapes; the probe treats `def self.x` as part of shape B because
it is the same mechanism and the same non-answer. **A** is a walk that stops too
early — `walk_class_cvars` returns at a `DefNode` and never calls `gather_cvar_writes`
on a class body. **B** is not a walk gap at all: the write *is* collected, and
`StatementEvaluator#seed_instance_ivars` then declines to seed it because the body is
a singleton one (`return body_scope if singleton`). **C** is a prefix gap: at the top
level `collect_def_ivar_writes` returns on `qualified_prefix.empty?`.

## Why a movable-site probe rather than a diagnostic diff

Same reason as [#692](https://github.com/rigortype/rigor/pull/692): a `Dynamic`
receiver dispatches gradually, so none of these can fire `call.undefined-method` and
a before/after diagnostic diff over a corpus reads zero whether the shapes are
everywhere or absent. The probe is Prism-only, with Rigor deliberately out of the
loop, so the counts do not depend on the analyzer being sized.

The column that decides is **movable**: the rvalue is recoverable (a constant, a
`Const.new`, or a literal — an opaque rvalue records `Dynamic` after a fix too) **and**
at least one read of that name is the receiver of a call **in a different method from
the write**. The cross-method clause is what separates a real gap from the dominant
idiom, and it removes two thirds of the raw population:

```ruby
def producer(id, ...)
  @producers ||= {}          # the write the probe sees
  @producers[id.to_sym] = …  # the read — same body, flow already types it
end
```

That is `lib/rigor/plugin/base.rb:113`, and it is what most of shape B's 605 sites
look like. A census seed buys nothing there.

## Results

14 targets, 17,706 parsed files. `sites` is exact; `with_read` is a **floor** (a class
reopened in a file outside the run contributes no reads); `movable` is a **ceiling**
(it does not check that the recovered type reaches a diagnostic).

### A — class-body `@@x = …` never censused

| target | files | sites | recoverable | with_read | movable | collides |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| rigor `lib`,`plugins` | 674 | 0 | 0 | 0 | 0 | 0 |
| mastodon | 1,325 | 0 | 0 | 0 | 0 | 0 |
| gitlab | 11,344 | 11 | 11 | 11 | 11 | 0 |
| redmine | 346 | 15 | 12 | 10 | 7 | 0 |
| rails | 2,829 | 18 | 9 | 11 | 5 | 0 |
| mail | 111 | 5 | 4 | 4 | 3 | 0 |
| liquid | 63 | 2 | 2 | 2 | 1 | 0 |
| kramdown | 55 | 1 | 1 | 1 | 1 | 0 |
| dependabot-core, concurrent-ruby, haml, faraday, parser, rubocop-ast | 959 | 0 | 0 | 0 | 0 | 0 |
| **total** | **17,706** | **52** | **39** | **39** | **28** | **0** |

### B — ivar writes in `class << self` / `def self.x` not seeded

| target | files | sites | recoverable | with_read | movable | collides |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| gitlab | 11,344 | 321 | 81 | 77 | 8 | 1 |
| rails | 2,829 | 152 | 58 | 52 | 4 | 2 |
| redmine | 346 | 36 | 17 | 26 | 5 | 0 |
| rigor `lib`,`plugins` | 674 | 29 | 12 | 8 | 2 | 0 |
| mastodon | 1,325 | 22 | 14 | 4 | 0 | 0 |
| faraday | 33 | 12 | 5 | 0 | 0 | 0 |
| dependabot-core | 540 | 8 | 3 | 6 | 3 | 0 |
| parser | 56 | 8 | 8 | 0 | 0 | 0 |
| concurrent-ruby | 178 | 6 | 4 | 4 | 2 | 0 |
| liquid | 63 | 5 | 1 | 4 | 1 | 0 |
| kramdown | 55 | 4 | 0 | 2 | 0 | 0 |
| haml, rubocop-ast | 152 | 2 | 1 | 1 | 0 | 0 |
| **total** | **17,706** | **605** | **204** | **184** | **25** | **3** |

### C — ivar writes in `Class.new do … end`

| target | files | sites | recoverable | with_read | movable | collides |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| rails | 2,829 | 22 | 15 | 5 | 2 | 2 |
| dependabot-core | 540 | 9 | 2 | 9 | 0 | 0 |
| gitlab | 11,344 | 4 | 2 | 2 | 1 | 0 |
| everything else | 2,993 | 0 | 0 | 0 | 0 | 0 |
| **total** | **17,706** | **35** | **19** | **16** | **3** | **2** |

## Adjudication

**The movable sites are real, and they are all the same site.** Every one of shape A's
28 is a registry table on a plugin manager — `Redmine::Activity.@@available_event_types`,
`Redmine::WikiFormatting.@@formatters`, `Mail.@@delivery_interceptors`,
`Kramdown::Parser::Kramdown.@@parsers`, gitlab's five `Gitlab::Testing::*` middlewares.
Verified on the real tree rather than inferred:

```
$ rigor type-of lib/redmine/activity.rb:42:9   # `@@available_event_types << event_type`
type:    Dynamic[top]
```

Shape B's 25 are the same idiom one facet up (`@permissions`, `@registered_plugins`,
`@scms`, `@stubs`), and shape C's 3 are two RSpec-adjacent `Class.new` blocks in
`rails/…/test/` plus one gitlab config walker.

**And the recovered type stops one hop in.** The rvalue mix says so: across all three
shapes the recoverable rvalues are `[]`, `{}`, `Mutex.new`, `Hash.new { … }` — a
collection whose *element* type is untyped. Recovering it turns
`@@available_event_types` from `Dynamic[top]` into `Array[untyped]`, which resolves
`<<`, `delete` and `include?` and then hands `untyped` to whatever reads an element.
So the gain is not a type that flows; it is teeth against a mistyped collection method
on 28 + 25 + 3 receivers corpus-wide — about one site per 300 files, on code that is
correct today and therefore reports nothing before or after.

**One correction to the issue's premise, in the FP direction.** #693 says "neither
produces a wrong answer". For shapes B and C that is not true: the write is not lost,
it is recorded against the *enclosing class's instance facet*, because
`collect_def_ivar_writes` keys the census table per class with no facet split and a
`class << self` def carries no receiver to mark it singleton. Both of these are correct
Ruby and both fire on master:

```ruby
class SingletonMix
  def initialize = (@state = Post.new)
  class << self
    def configure = (@state = Comment.new)   # warning: def.ivar-write-mismatch
  end
end

class Outer
  def initialize = (@own = Post.new)
  Inner = Class.new do
    def initialize = (@own = Comment.new)    # warning: def.ivar-write-mismatch
  end
end
```

`def self.x` does not fire — the write-mismatch collector recognises that spelling as
singleton and `class << self` is not, which is the same two-spellings-one-meaning
asymmetry [#681](https://github.com/rigortype/rigor/issues/681) was about. The probe
counts this population as `collides` (the gap-shape write shares a census slot with an
ordinary `def`'s write of the same name): **5 sites corpus-wide**, at
`activesupport/lib/active_support/key_generator.rb:18,25`,
`lib/gitlab/database/connection_timer.rb:22`, and two rails test files. **None fires
today** — each pairs one known type against one opaque one, and the mismatch check
declines. Both files were run to confirm that rather than argued from the shape.

## Decision — not worth doing

**The shapes are rare and the recovered types move nothing, so this is not worth
doing.** Concretely, per shape:

- **A** is the strongest of the three and still does not clear the bar: 28 movable
  sites in 6 of 14 targets, each recovering a bare collection. Against that, a
  class-body `@@x = nil` (3 sites: rails' `@@app`, `@@parallel_worker_id`, redmine's
  `@@listeners`) would union `nil` into every read of that cvar in the class, which is
  exactly the widening ADR-58 WD1's declaration-sourced mark and the C2 dead-write
  elimination were built to keep out of the ivar path. Paying that guarding cost for
  28 collection receivers is the wrong trade under the FP-first rule.
- **B** is not a walk fix. `seed_instance_ivars` declines singleton bodies *because*
  the census table has no facet split, so closing it means splitting the table — a real
  engine change with its own FP budget — for 25 sites, 2 of which are in Rigor's own
  `lib/`.
- **C** is 3 movable sites, two of them under `test/`. What it actually needs is the
  opposite of seeding: the anonymous class's writes should stop being attributed to the
  enclosing class.

The by-product is the part worth keeping open. The facet conflation under B and C is a
**wrong type**, not a precision gap, and it is one distinct-nominals-on-both-facets away
from a false `def.ivar-write-mismatch`. It is also much cheaper than seeding: marking a
`class << self` def as singleton for the write-mismatch collector is a spelling fix, not
a table split. That half should be its own issue, sized by the `collides` column
(5 sites, 0 firing) rather than by the movable one.

## What this note does not do

- It does not check that a movable site's *receiver* would be RBS-known. It does not
  have to: every recovered type here is a core collection, so the ceiling is already
  the optimistic reading and the conclusion is a decline anyway.
- It does not size the same three shapes for `Struct.new do … end` or
  `class << SomeConstant`, both of which the probe skips deliberately.
