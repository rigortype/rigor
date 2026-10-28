# Another file's writes, and an included module's or superclass's, join a class's existing ivar census entries

- **PR:** [#2486](https://github.com/rigortype/rigor/pull/2486)
- **Issue:** [#2079](https://github.com/rigortype/rigor/issues/2079)
- **Class:** open-choice
- **Precedent:** [ADR-58](../docs/adr/58-ivar-field-typing.md)
- **Decided:** 2026-10-28

## Background

The class-ivar census that seeds every instance method's ivars is built per file, keyed by the write's lexical
owner. A write in another file's reopening of the class (#2079), or in a module the class includes or prepends, or
in a superclass (#2170), never reached the class's seed. So the seed could be narrower than anything the program
stores: `@x = nil` in `initialize` with `def set = (@x = "a")` in another file, or in an included module, read `@x`
as `nil` and reported `upcase` on it; `@y = false; other; if @y` folded always-falsey when `other` lived in another
file. The issues left open how far to credit those writes, how to type another file's rvalue, and how the
incremental cache learns of a change. The coordinator ruled on the shape (existing entries only; a literal as its
`Constant`, anything else `Dynamic[top]`; superclasses in scope; a type-change incremental key); this entry records
it as an ADR-58 amendment for ratification.

## Options and trade-offs

- Leave the census per file: keeps every check on those ivars, and every false positive above.
- Join other files' and the chain's writes into the entries the file already holds, typed coarsely (chosen).
  Fixes the false positives. Creates no entry, so an ivar only another file writes still reads `Dynamic[top]`.
  A `nil` / boolean / number / symbol literal joins as its `Constant`; a String literal joins as `String` (the
  coordinator's review amendment: a String may be mutated in place where its write cannot see it, so its literal
  would pin the value too narrowly); anything else as `Dynamic[top]`.
- Also create entries for ivars only another file or an ancestor writes: more precision, but narrows reads that
  are `Dynamic` today and could add rows.
- Type another file's rvalue as the census would: precise, but needs a typed pass over every other file.

## Decision

Ruling: **accepted, pending ratification.** The coordinator accepts the two review-round losses below (a `nil`
written elsewhere, and a String literal read as `String`) under ADR-5.

The second option, recorded as the ADR-58 amendment "cross-file and chain census contributions". These true
positives are lost (each needs the ivar to already have an entry in the reading file's census for the class):

- **A non-literal write elsewhere hides the ivar's type.** A write in another file's reopening of the class, or in a
  project module or superclass on its chain, whose value is not a `nil` / boolean / number / string / symbol literal
  (a parameter, a method call, an operator write, a multiple assignment, an `attr_writer` / `attr_accessor`) joins as
  `Dynamic[top]`. Every read of that ivar in the class then stops reporting `call.undefined-method`, argument-type
  mismatches and condition folds that relied on the precise type, even when the written value has the same type.
- **A write that never runs still widens.** Crediting is flow-free and chain-wide: a module method or superclass
  method the class never calls, or a reopening's method nobody calls, still adds its value. A fold such as
  `@y = false; other; if @y` stays quiet even when no path from the read runs a `true` write, and a `nil`-only entry
  joined with a string written in an unused module method no longer reports `upcase` on `nil`.
- **A `nil` from elsewhere is declaration-sourced.** A `nil` another file or an ancestor writes joins the seed, so,
  as for every seed `nil` (ADR-58 WD1), it is not fuel for `call.possible-nil-receiver`.
- **A superclass write reaches every subclass's entry**, including a subclass that overrides the writing method.
- **An all-truthy union loses its fold.** `@mode = true` here and `@mode = :on` in another file join to
  `true | :on`, which Rigor does not fold, so an `if @mode` that is always truthy no longer reports.
- **A String literal reads as `String` once another file or an ancestor writes the ivar.** That covers this
  file's own literal too: `@s = "x"` here and `@s = "y"` elsewhere join to `String`, so the `@s == "q"`
  always-falsey row goes. Any other check that needed the literal (a literal-keyed dispatch) stops as well.
- **A `nil` written anywhere else makes every method check on the ivar go quiet.** A `nil` written in another
  file, an included module or a superclass's `initialize` turns `K`'s entry into `T?`, and the seed's `nil` is
  declaration-sourced, so every method check on that ivar in `K` goes quiet, as the same-file census already
  does. The common superclass idiom is the witness:

  ```ruby
  class Base; def initialize = (@x = nil); end
  class Sub < Base; def initialize; super; @x = Integer.sqrt(4); end; def r = @x.upcase; end
  ```

  Base reports `upcase` for Integer; head is quiet; Ruby 4.0.5 raises `NoMethodError`. Two more rows go the
  same way: `@s = 1` here and `@s = nil` elsewhere, then `@s.upcase`; and `@s = nil` here and `@s = :b`
  elsewhere, then `@s.even?`. Ruby raises on each.
- **A write inside `other.instance_eval { @x = … }` in an instance method is credited to the class** (#2490). The
  census already did so in the same file; a reopening in another file now reaches the class's entry too.
- **A module's own census takes no chain** (#2487): a read inside a module's method does not see the writes of the
  modules it includes.

What still reports: an ivar whose writes, across every file and ancestor, are all `nil` (or all values of a type
that lacks the method); a write in a singleton method (`def self.set`) or through `extend`, which never joins an
instance entry; and a write in a `self.included(base)` hook or an `include(Module.new { … })` block, which this
change does not credit (#1958).

## To undo

Remove the `IvarContributions.join!` call in `ScopeIndexer#build_class_ivar_index`. The `:own_write_type` census
entries and the `own_write_type:` incremental key can stay or go with it; the cache schema bump (47) should stay
so warm bundles stay consistent. The fixtures under `spec/integration/fixtures/cross_file_ivar_census/` and
`spec/rigor/analysis/cross_file_ivar_census_incremental_spec.rb` pin the current behaviour.
