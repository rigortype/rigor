# frozen_string_literal: true

require "spec_helper"

# ADR-48 Struct follow-up — `Struct.new` value folding, exercised end-to-end through the full Runner pipeline (the
# project pre-pass that builds the class-name -> member-layout side-table only runs there). The distinguishing property
# versus the immutable `Data` sibling: a `Struct` is mutable, so a member read folds only off a FRESH (chained)
# instance; a read off a STORED binding soundly degrades to `Dynamic[top]`.
RSpec.describe "Struct.new value folding", type: :runner do
  # Returns the `describe(:short)` strings recorded by each `dump_type(...)` call in source order.
  def dumped_types(source)
    result = analyze("require \"rigor/testing\"\ninclude Rigor::Testing\n#{source}")
    result.diagnostics
          .select { |d| d.message.start_with?("dump_type") }
          .map { |d| d.message.delete_prefix("dump_type: ") }
  end

  describe "the class object and fresh-chain folding" do
    it "folds Struct.new, .members, .new, fresh member reads, and projections" do
      types = dumped_types(<<~RUBY)
        c = Struct.new(:x, :y)
        dump_type(c)
        dump_type(c.members)
        dump_type(c.new(1, "two"))
        dump_type(c.new(1, "two").x)
        dump_type(c.new(1, "two").y)
        dump_type(c.new(1, "two")[:x])
        dump_type(c.new(1, "two")[1])
        dump_type(c.new(1, "two").to_h)
        dump_type(c.new(1, "two").deconstruct)
      RUBY

      expect(types).to eq([
                            "Struct.new(:x, :y)",
                            "[:x, :y]",
                            "Struct(x: 1, y: \"two\")",
                            "1", "\"two\"",  # fresh .x, .y
                            "1", "\"two\"",  # fresh [:x], [1]
                            "{ x: 1, y: \"two\" }",
                            "[1, \"two\"]"
                          ])
    end

    it "defaults omitted trailing members to nil" do
      expect(dumped_types(<<~RUBY)).to eq(%w[1 nil])
        c = Struct.new(:a, :b)
        dump_type(c.new(1).a)
        dump_type(c.new(1).b)
      RUBY
    end

    it "folds Struct#with off a fresh instance" do
      expect(dumped_types(<<~RUBY)).to eq(["99", "\"two\""])
        c = Struct.new(:x, :y)
        dump_type(c.new(1, "two").with(x: 99).x)
        dump_type(c.new(1, "two").with(x: 99).y)
      RUBY
    end
  end

  describe "mutation soundness" do
    it "models a member setter as returning the assigned value" do
      expect(dumped_types(<<~RUBY)).to eq(["5"])
        c = Struct.new(:x)
        p = c.new(1)
        dump_type(p.x = 5)
      RUBY
    end

    it "does NOT fold a member read off an unrecognised local-class binding" do
      # `p = c.new(1)` where `c` is a local StructClass is conservatively not treated as a fold-safe materialisation
      # (the scan resolves the constant and inline forms, not a local-class intermediate) — degrades, never a stale
      # value.
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        c = Struct.new(:x)
        p = c.new(1)
        dump_type(p.x)
      RUBY
    end
  end

  describe "fold-safe bound locals (slice 3)" do
    it "folds a member read off a never-mutated bound local" do
      expect(dumped_types(<<~RUBY)).to eq(["1", "\"two\""])
        Point = Struct.new(:x, :y)
        p = Point.new(1, "two")
        dump_type(p.x)
        dump_type(p.y)
      RUBY
    end

    it "folds a never-mutated bound local materialised inline" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        p = Struct.new(:x).new(1)
        dump_type(p.x)
      RUBY
    end

    # Issue #589 — a merge must not revoke the grant. `Scope#join` omitted the fold-safe set from its
    # constructor, so it fell back to the empty default and EVERY `if` / `while` in a method silently
    # stopped struct folding for the rest of the body. The carrier survived the merge intact; only the
    # grant that lets a read consult it was lost, which is why the shape read as carrier erasure.
    it "folds after a loop whose body never touches the struct" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        Point = Struct.new(:x, :y)
        def reader(n)
          p = Point.new(1, 2)
          i = 0
          while i < n
            i += 1
          end
          dump_type(p.x)
        end
      RUBY
    end

    # The same seam, reached through an `if` — this was never loop-specific.
    it "folds after a conditional whose branches never touch the struct" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        Point = Struct.new(:x, :y)
        def reader(cond)
          p = Point.new(1, 2)
          if cond
            puts "side effect"
          end
          dump_type(p.x)
        end
      RUBY
    end

    # …and it holds across the ADR-56 loop fixpoint rather than for one pass: a read INSIDE a later loop
    # sees the grant too.
    it "folds inside a later loop body after an untouching loop" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        Point = Struct.new(:x, :y)
        def reader(cond, n)
          p = Point.new(1, 2)
          i = 0
          while i < n
            i += 1
          end
          while cond
            dump_type(p.x)
          end
        end
      RUBY
    end

    # The must-still-decline half. A setter inside a block or a loop is disqualified up front by the static
    # body scan, for two DIFFERENT reasons that are easy to conflate: a block's bindings never leave its own
    # scope (#525's sibling verified the read then serves the stale materialisation `nil`), while a loop's
    # DO reach the continuation, but only as a single unrolling — which is not a per-iteration summary. See
    # `StructFoldSafety#deferred_boundary?` for the four side conditions that unrolling silently assumes.
    it "does NOT fold a member whose setter sits inside a block" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        def reader
          p = Point.new(1, 2)
          [1].each { p.x = 9 }
          dump_type(p.x)
        end
      RUBY
    end

    it "does NOT fold a member whose setter sits inside a loop" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        def reader(cond)
          p = Point.new(1, 2)
          while cond
            p.x = 9
          end
          dump_type(p.x)
        end
      RUBY
    end

    it "does NOT fold a local the loop body rebinds" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        def reader(cond)
          p = Point.new(1, 2)
          while cond
            p = Point.new(3, 4)
          end
          dump_type(p.x)
        end
      RUBY
    end

    # Issue #589 / review of #596 — the scan's counting identity is about the LOCAL, and says nothing about
    # a member read's RESULT. `s.x << v` mutates the container `s.x` returns while `s.x` is a pure read by
    # every measure the scan applies, so the local stayed fold-safe while its member's value changed
    # underneath: `s.x.last` folded to 5 and `.upcase` drew undefined-method on correct code.
    it "does NOT fold a member whose result is mutated through a chained call in a loop" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x)
        def reader(c)
          s = Point.new([5])
          while c
            s.x << "a"
          end
          dump_type(s.x.last)
        end
      RUBY
    end

    # The post-`if` form, read through a size the fold would answer 1 for while the runtime holds 2.
    it "does NOT fold a member whose result is mutated through a chained call in a branch" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Row = Struct.new(:cells)
        def reader(c)
          row = Row.new([1])
          if c
            row.cells.push(2)
          end
          dump_type(row.cells.size)
        end
      RUBY
    end

    # The STRAIGHT-LINE sibling, which fired before any of this branch's work: the merge fix extended the
    # exposure but did not create it, and tightening the scan removes the older false positive too.
    it "does NOT fold a member whose result is mutated through a chained call on the straight line" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x)
        def reader
          s = Point.new([5])
          s.x << "a"
          dump_type(s.x.last)
        end
      RUBY
    end

    # must-still-fold: the disqualifier is about CHAINING, not about branching or about member reads in
    # general. An untouched member read after a branch keeps its value.
    it "still folds an untouched member read after a branch" do
      expect(dumped_types(<<~RUBY)).to eq(["[5]"])
        Point = Struct.new(:x)
        def reader(c)
          s = Point.new([5])
          if c
            puts "side"
          end
          dump_type(s.x)
        end
      RUBY
    end

    # …and a member read that is an ARGUMENT rather than a receiver is not a chain, so it folds. This is
    # the shape every `dump_type(p.x)` / `assert_type(..., stored.foo)` in this suite relies on, and it is
    # what keeps the broad no-allow-list disqualifier from swallowing the feature.
    it "still folds a member read used as an argument rather than a receiver" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        Point = Struct.new(:x, :y)
        def reader(c)
          p = Point.new(1, 2)
          if c
            puts "side"
          end
          sink(p.y)
          dump_type(p.x)
        end
      RUBY
    end

    it "does NOT fold a bound local that escapes through an alias" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        q = p
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a bound local that escapes as a call argument" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        sink(p)
        dump_type(p.x)
      RUBY
    end

    it "folds a fold-safe bound local inside a method body" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        Point = Struct.new(:x, :y)
        def reader
          p = Point.new(1, 2)
          dump_type(p.x)
        end
      RUBY
    end
  end

  describe "precise mutated-member re-typing (slice 4)" do
    it "re-types a member read to the assigned value after a straight-line setter" do
      expect(dumped_types(<<~RUBY)).to eq(%w[5 2])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x = 5
        dump_type(p.x)
        dump_type(p.y)
      RUBY
    end

    it "reflects an incompatible-type mutation soundly (String into an Integer member)" do
      expect(dumped_types(<<~RUBY)).to eq(["\"hi\""])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x = "hi"
        dump_type(p.x)
      RUBY
    end

    it "threads several straight-line setters (last write wins)" do
      expect(dumped_types(<<~RUBY)).to eq(["6"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x = 5
        p.x = 6
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member setter inside a loop (iteration-specific)" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        while cond
          p.x = p.x + 1
        end
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member setter inside a block" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        [1].each { p.x = 9 }
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member read after a mutation through an alias" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        q = p
        q.x = 5
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member read after the local escapes to a callee" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        mutate!(p)
        dump_type(p.x)
      RUBY
    end
  end

  describe "the constant-assigned form" do
    it "folds a fresh member read off the constant, tagging the instance" do
      expect(dumped_types(<<~RUBY)).to eq(["Point(x: 1, y: \"two\")", "1"])
        Point = Struct.new(:x, :y)
        dump_type(Point.new(1, "two"))
        dump_type(Point.new(1, "two").x)
      RUBY
    end

    it "folds the Point[...] new alias" do
      expect(dumped_types(<<~RUBY)).to eq(["3"])
        Point = Struct.new(:x, :y)
        dump_type(Point[3, 4].x)
      RUBY
    end

    it "keeps the member layout visible inside a method body" do
      expect(dumped_types(<<~RUBY)).to eq(["3"])
        Point = Struct.new(:x, :y)
        def reader
          dump_type(Point.new(3, 4).x)
        end
      RUBY
    end
  end

  describe "the named-subclass form" do
    it "folds a fresh member read through the recorded layout" do
      expect(dumped_types(<<~RUBY)).to eq(["Coord(lat: 35, lng: 139)", "35"])
        class Coord < Struct.new(:lat, :lng)
        end
        dump_type(Coord.new(35, 139))
        dump_type(Coord.new(35, 139).lat)
      RUBY
    end
  end

  describe "keyword_init" do
    it "folds keyword construction by member name" do
      expect(dumped_types(<<~RUBY)).to eq(%w[10 20])
        KP = Struct.new(:x, :y, keyword_init: true)
        dump_type(KP.new(x: 10, y: 20).x)
        dump_type(KP.new(x: 10, y: 20).y)
      RUBY
    end

    it "degrades a positional call on a keyword_init struct (wrong form)" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        KP = Struct.new(:x, :y, keyword_init: true)
        dump_type(KP.new(1, 2).x)
      RUBY
    end
  end

  describe "degradation (precision floors, never a wrong answer)" do
    it "degrades a positional arity overflow to Dynamic" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        c = Struct.new(:x)
        dump_type(c.new(1, 2).x)
      RUBY
    end

    it "does not fold non-literal members" do
      types = dumped_types(<<~RUBY)
        names = [:x, :y]
        c = Struct.new(*names)
        dump_type(c.new(1, 2).x)
      RUBY
      expect(types.first).not_to eq("1")
    end
  end

  # Issue #293. A member holds a REFERENCE to the container the constructor was handed, so an empty literal's
  # emptiness is a fact about that argument at construction time, not about the member: "construct empty, then
  # fill" is the dominant idiom, and the pin is the only member fact whose reads fold to `nil` — the receiver
  # type that fires `call.undefined-method` on correct code. Both directions are pinned here: the empty literal
  # widens, everything else keeps folding exactly as before.
  describe "empty-container members (issue #293)" do
    it "widens an empty Array / Hash literal member to its bare nominal" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "Hash[Dynamic[top], Dynamic[top]]"])
        Result = Struct.new(:items, :opts)
        dump_type(Result.new([], {}).items)
        dump_type(Result.new([], {}).opts)
      RUBY
    end

    it "keeps a NON-empty container member folding precisely" do
      expect(dumped_types(<<~RUBY)).to eq(["[1, 2]", "1", "{ a: 1 }"])
        Result = Struct.new(:items, :opts)
        dump_type(Result.new([1, 2], { a: 1 }).items)
        dump_type(Result.new([1, 2], { a: 1 }).items.first)
        dump_type(Result.new([1, 2], { a: 1 }).opts)
      RUBY
    end

    it "leaves every non-container member untouched" do
      expect(dumped_types(<<~RUBY)).to eq(["1", "\"two\"", "nil"])
        Result = Struct.new(:x, :y, :z)
        dump_type(Result.new(1, "two").x)
        dump_type(Result.new(1, "two").y)
        dump_type(Result.new(1, "two").z)
      RUBY
    end

    it "widens an empty literal assigned through a member setter" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]"])
        Result = Struct.new(:items)
        r = Result.new([1])
        r.items = []
        dump_type(r.items)
      RUBY
    end

    it "widens an empty literal introduced by #with" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "[1]"])
        Result = Struct.new(:items, :other)
        dump_type(Result.new([1], [2]).with(items: []).items)
        dump_type(Result.new([1], [2]).with(other: []).items)
      RUBY
    end

    # The issue's repro, single-file: the member is filled by `<<` right after construction and read through the
    # factory's return, so a surviving empty-literal pin folds `.first` to `nil` and fires on correct code.
    it "stays silent on a member filled after construction" do
      result = analyze(<<~RUBY)
        module Pkg
          class Parser
            Result = Struct.new(:items, :errors)
            def self.parse(text)
              r = Result.new([], [])
              text.split(",").each { |t| r.items << Item.new(t) }
              r
            end
          end
          class Item
            def initialize(name) = @name = name
            def local = @name
          end
        end

        Pkg::Parser::Result.new([], []).items.first.local
      RUBY
      expect(result.diagnostics.map(&:message).join("\n")).not_to match(/undefined method/i)
    end

    # The must-still-succeed control for the example above: the same chain over a NON-empty member still folds to
    # a real element type, so a genuine typo on it is still reported. Without this the silence above could come
    # from the whole chain having degraded rather than from the widening.
    #
    # Issue #595 moved both examples off the FACTORY-METHOD receiver they used to carry
    # (`Pkg::Parser.parse("a,b").items`, `build.items`). A chained call is no longer read as fresh, so that
    # receiver now declines — which would have left the silence example passing for the wrong reason and this
    # control failing. A direct materialisation keeps the pair discriminating over exactly the widening it was
    # written for; the factory-method route's own decline is pinned in the #595 block below.
    it "still reports a genuine typo reached through a non-empty member" do
      result = analyze(<<~RUBY)
        Pair = Struct.new(:label, :items)
        Pair.new("hi", [1, 2]).items.first.zzz_undefined
      RUBY
      expect(result.diagnostics.map(&:message).join("\n")).to include("zzz_undefined")
    end
  end

  describe "false-positive safety" do
    it "does not flag a member read as an undefined method" do
      result = analyze(<<~RUBY)
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x
      RUBY
      expect(result).to be_success
      expect(result.diagnostics.map(&:message).join).not_to match(/undefined method/i)
    end

    it "resolves a non-member call through the Struct nominal without mis-firing" do
      result = analyze(<<~RUBY)
        c = Struct.new(:x, :y)
        dump_type(c.new(1, 2).frozen?)
        dump_type(c.new(1, 2).to_s)
      RUBY
      expect(result).to be_success
      expect(result.diagnostics.map(&:message).join).not_to match(/undefined method/i)
    end
  end

  # Issue #525 — the in-body member read. A block-def method resolved on a foldable struct receiver re-types
  # its body with the caller's `StructInstance` as `self_type`; before this the receiverless `text` read had
  # no receiver NODE to prove foldability from and degraded to `Dynamic[top]`, taking the whole method's
  # return with it. The caller now records its own receiver's foldability as the `:self` sentinel in the
  # body scope's fold-safe set.
  describe "in-body member reads through the `:self` sentinel" do
    let(:line_def) { <<~RUBY }
      Line = Struct.new(:text, :indent) do
        def shout
          text.upcase
        end

        def explicit
          self.text.upcase
        end

        def outer
          shout
        end

        def clobber
          self.text = "z"
          text.upcase
        end

        def reset!
          self.text = ""
        end

        def via_sibling
          reset!
          text.upcase
        end

        def escaping(sink)
          sink.take(self)
          text.upcase
        end

        def two_hops
          via_sibling
          text.upcase
        end

        def with_text(v)
          self.text = v
          self
        end

        def ping
          pong
        end

        def pong
          ping
        end
      end
    RUBY

    describe "must fold — the caller proved its receiver current" do
      it "folds an implicit-self member read off a fresh receiver" do
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).shout)")).to eq(["\"A\""])
      end

      it "folds an explicit `self.member` read the same way" do
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).explicit)")).to eq(["\"A\""])
      end

      it "propagates the grant through a nested implicit-self call" do
        # `outer` has no member read of its own; the grant has to reach `shout`'s body through the
        # receiverless `shout` call for this to fold.
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).outer)")).to eq(["\"A\""])
      end

      it "folds off a `.with` copy" do
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).with(text: \"b\").shout)")).to eq(["\"B\""])
      end

      it "folds each call site against ITS OWN carrier, not a shared answer" do
        types = dumped_types(<<~RUBY)
          #{line_def}
          dump_type(Line.new("a", 2).shout)
          dump_type(Line.new("b", 3).shout)
        RUBY
        expect(types).to eq(["\"A\"", "\"B\""])
      end
    end

    describe "must decline — the map may be stale by the read" do
      it "declines a body that assigns the member before reading it" do
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).clobber)")).to eq(["Dynamic[top]"])
      end

      it "declines a body that calls a sibling mutator before reading" do
        # The read would fold to the CONSTRUCTION value while the runtime read is `""`. The body has no
        # setter of its own, so a guard that only looked for direct setters would fold this wrongly.
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).via_sibling)")).to eq(["Dynamic[top]"])
      end

      it "declines a body that lets self escape" do
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).escaping(x))")).to eq(["Dynamic[top]"])
      end

      it "declines a chain through a self-returning fluent builder" do
        # `with_text` hands back its own receiver AFTER writing a member, so the chained `.shout` runs on an
        # object two statements stale. A "any chained call is fresh" reading folds `"A"` here; the runtime
        # value is `"Z"`. Only recognised MATERIALISATIONS (`.new` / `.[]` / `.with`) count as fresh for the
        # grant — the sibling examples above are the must-still-fold controls for that narrowing.
        source = "#{line_def}dump_type(Line.new(\"a\", 2).with_text(\"z\").shout)"
        expect(dumped_types(source)).to eq(["Dynamic[top]"])
      end

      it "declines transitively — a sibling of a sibling that mutates" do
        # `two_hops` -> `via_sibling` -> `reset!`, which writes the member. The refusal has to travel two
        # resolution hops, so a one-level sibling check would fold this wrongly.
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).two_hops)")).to eq(["Dynamic[top]"])
      end

      it "declines a mutually recursive pair rather than looping" do
        # `ping` -> `pong` -> `ping`. The cycle guard refuses (the conservative direction) instead of
        # recursing; the assertion doubles as the non-hang control.
        expect(dumped_types("#{line_def}dump_type(Line.new(\"a\", 2).ping)")).to eq(["Dynamic[top]"])
      end

      it "declines when the CALL SITE receiver is not foldable" do
        # `v.shout` is not a pure read, so `v` never enters the fold-safe set and the call site cannot vouch
        # for its member map.
        expect(dumped_types("#{line_def}v = Line.new(\"a\", 2)\ndump_type(v.shout)")).to eq(["Dynamic[top]"])
      end
    end

    describe "the grant is part of the return-memo key" do
      # The same def, the same receiver carrier and the same (empty) argument list, called once from a
      # foldable site and once from a non-foldable one. Without the fold-safety bit in the memo key the
      # first call site to run answers for both — and in the fresh-first order that serves `"A"` for a read
      # off a local nothing proved current, a wrong type rather than mere imprecision.
      it "keeps the two polarities apart with the foldable site first" do
        types = dumped_types(<<~RUBY)
          #{line_def}
          dump_type(Line.new("a", 2).shout)
          v = Line.new("a", 2)
          dump_type(v.shout)
        RUBY
        expect(types).to eq(["\"A\"", "Dynamic[top]"])
      end

      it "keeps them apart in the opposite order too" do
        types = dumped_types(<<~RUBY)
          #{line_def}
          v = Line.new("a", 2)
          dump_type(v.shout)
          dump_type(Line.new("a", 2).shout)
        RUBY
        expect(types).to eq(["Dynamic[top]", "\"A\""])
      end
    end

    describe "must still decline — the pre-existing fold-safety floor is unmoved" do
      it "declines a member read off a local that escaped to an unknown method" do
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          Point = Struct.new(:x, :y)
          p = Point.new(1, 2)
          sink(p)
          dump_type(p.x)
        RUBY
      end
    end
  end

  # Issue #595 — slice 2's freshness test read "the receiver is a chained call" as "the receiver is a
  # transient nothing else holds". A method that returns its own receiver falsifies that, and the fluent
  # builder is ordinary Ruby, so the gate served construction-time member values against a mutated object.
  # The test now recognises MATERIALISATIONS only, sharing one implementation with the slice-5 `:self` grant.
  describe "freshness is materialisation, not chaining" do
    let(:builder_def) { <<~RUBY }
      Line = Struct.new(:text, :indent) do
        def with_text(v)
          self.text = v
          self
        end

        def dup_self
          self
        end

        def shout
          text.upcase
        end
      end
    RUBY

    describe "must stay Dynamic — the chain hands back a mutated object" do
      it "declines a read through a self-returning fluent setter" do
        # Runtime `"z"`; the pre-fix gate folded the construction-time `"a"`.
        source = "#{builder_def}dump_type(Line.new(\"a\", 2).with_text(\"z\").text)"
        expect(dumped_types(source)).to eq(["Dynamic[top]"])
      end

      it "declines a read through a bare self-returning method after a setter" do
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          #{builder_def}
          x = Line.new("a", 2)
          x.text = "z"
          dump_type(x.dup_self.text)
        RUBY
      end

      it "declines a `.with` copy taken off a stale-derived receiver" do
        # The composed shape: `.with` IS a materialisation, but its receiver is not, so the copy it
        # produces carries the stale map. Refusing the prefix kills the composition at its root.
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          #{builder_def}
          x = Line.new("a", 2)
          x.text = "z"
          dump_type(x.dup_self.with(indent: 9).text)
        RUBY
      end

      it "declines a block-def method call off that same stale-derived receiver" do
        # The slice-5 grant fires off `.with`'s carrier, so the same prefix leaked into whole method
        # bodies: this folded `"A"` against a runtime `"Z"` with the grant's own arm behaving correctly.
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          #{builder_def}
          x = Line.new("a", 2)
          x.text = "z"
          dump_type(x.dup_self.with(indent: 9).shout)
        RUBY
      end
    end

    describe "must still fold — the receiver really was just materialised" do
      it "folds a read off `.new`" do
        expect(dumped_types("#{builder_def}dump_type(Line.new(\"c\", 2).text)")).to eq(["\"c\""])
      end

      it "folds a read off `[]`" do
        expect(dumped_types("#{builder_def}dump_type(Line[\"d\", 2].text)")).to eq(["\"d\""])
      end

      it "folds a read off a `.with` copy of a materialisation" do
        source = "#{builder_def}dump_type(Line.new(\"e\", 2).with(text: \"f\").text)"
        expect(dumped_types(source)).to eq(["\"f\""])
      end

      it "folds a projection off a materialisation" do
        source = "#{builder_def}dump_type(Line.new(\"h\", 2).to_h)"
        expect(dumped_types(source)).to eq(["{ text: \"h\", indent: 2 }"])
      end

      it "keeps the slice-5 grant firing off a materialisation" do
        expect(dumped_types("#{builder_def}dump_type(Line.new(\"g\", 2).shout)")).to eq(["\"G\""])
      end
    end

    describe "the measured precision trade" do
      it "declines a genuinely fresh helper return (the accepted cost)" do
        # `make` really does hand back a new instance, but the whitelist cannot see through it. Accepted:
        # a before/after run over haml's and hamlit's parsers, faraday's Options/Request and mail's
        # received_parser showed an identical diagnostic set and identical `type-scan` coverage, because a
        # helper return at those sites does not infer to a StructInstance in the first place. The richer
        # fix (consult the callee's return for a self-alias) is issue #599.
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          #{builder_def}
          def make = Line.new("x", 1)
          dump_type(make.text)
        RUBY
      end

      it "declines the factory-method route, and the direct one still reports the typo" do
        # The paired form of the trade, over the shape the #293 guards above used to carry. The factory
        # return is genuinely fresh, but the whitelist cannot see through `parse`, so the chain declines and
        # a typo on it goes unreported; written as a direct materialisation the same typo still fires. The
        # loss direction is a missed error, never a diagnostic on correct code — and closing it needs the
        # callee's return consulted for a `self` alias — issue #599.
        factory = <<~RUBY
          Pair = Struct.new(:label, :items)
          def build = Pair.new("hi", [1, 2])
        RUBY
        via_factory = analyze("#{factory}build.items.first.zzz_undefined")
        direct = analyze("#{factory}Pair.new(\"hi\", [1, 2]).items.first.zzz_undefined")

        expect(via_factory.diagnostics.map(&:message).join("\n")).not_to include("zzz_undefined")
        expect(direct.diagnostics.map(&:message).join("\n")).to include("zzz_undefined")
      end
    end

    describe "a hand-written `with` is not a materialisation" do
      # The guard resolves `with` through the ancestor walk, so BOTH consumers of the shared predicate — the
      # direct member read here and the `:self` grant that types a whole body — get the same answer. They
      # did not while the guard read the own-class table only: an included `with` was invisible to it and a
      # read folded off a receiver the grant arm refused (#598 review).
      let(:warm_module) { <<~RUBY }
        module Warm
          def with(**)
            self
          end
        end
      RUBY

      it "declines a member read through a `with` an included module supplies" do
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          #{warm_module}
          class Line < Struct.new(:text, :indent)
            include Warm
          end
          dump_type(Line.new("a", 2).with(text: "q").text)
        RUBY
      end

      it "declines a block-def method call off that same receiver (the grant consumer)" do
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          #{warm_module}
          class Line < Struct.new(:text, :indent)
            include Warm

            def shout
              text.upcase
            end
          end
          dump_type(Line.new("a", 2).with(text: "q").shout)
        RUBY
      end

      it "still folds both consumers when no user `with` exists anywhere" do
        # The must-still-fold sibling: without it the two declines above would be satisfied by a guard that
        # simply refused every `.with`.
        expect(dumped_types(<<~RUBY)).to eq(["\"c\"", "\"C\""])
          class Plain < Struct.new(:text)
            def shout
              text.upcase
            end
          end
          dump_type(Plain.new("b").with(text: "c").text)
          dump_type(Plain.new("b").with(text: "c").shout)
        RUBY
      end

      it "declines a `.with` the struct defined itself" do
        # A user `with` is free to return `self`, which would reopen the whole family through the one
        # non-`new` name on the whitelist.
        expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
          Pair = Struct.new(:a, :b) do
            def with(**opts)
              self.a = opts[:a]
              self
            end
          end
          x = Pair.new(1, 2)
          x.a = 9
          dump_type(x.with(a: 3).a)
        RUBY
      end
    end
  end
end
