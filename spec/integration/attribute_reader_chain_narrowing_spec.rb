# frozen_string_literal: true

require "spec_helper"

# Issue #2685 — a truthiness or `nil?` guard on `x.r` carries to the next `x.r` read when `r` is declared with
# `attr_reader` / `attr_accessor` in the RBS of the receiver's class or an RBS ancestor, and the project cannot answer
# `r` another way. The fact is the single-hop method-chain narrowing `is_a?` guards already record, dropped by the same
# rules (a rebind of the root, any later call on it) and by three more for this kind of fact: a call whose block or
# lambda mentions the root, a call that runs a closure, and, for an instance-variable root, an implicit-self call. Such
# a fact never makes `flow.always-truthy-condition` fire.
#
# Each example passes the re-read to `Sink#int(Integer)`: a narrowed read is quiet, an un-narrowed one reports
# `call.argument-type-mismatch`. Ruby 4.0.5 behaviour the rule relies on, witnessed with `ruby -e`:
# - two reads of an `attr_reader` with no write between return the same object, and `nil&.r` returns `nil` without
#   calling `r`;
# - each of these makes the next read `nil` (or differ from the last): the writer `x.w = nil`, `x.w &&= nil`,
#   `x.w, _ = nil, 1`, `for x.w in [nil]`, a block or lambda writing `x.w` (`[1].each { … }`, `clear.call`,
#   `clear.()`), a `reset!` writing `@x.w`, an alias `y = x; y.w = nil`, and a method handed `x` that writes it;
# - a subclass `def r`, a `define_method(:r)`, a `refine … def r` under `using`, and a `define_singleton_method(:r)` in
#   `initialize` each answer `r` in place of the attribute.
#
# An example marked "guard" passes without the fix too; the comment says what it pins.
RSpec.describe "attribute-reader chain narrowing on truthiness and nil? guards (#2685)", type: :runner do
  let(:sig) do
    <<~RBS
      class Holder
        attr_reader r: Integer?
        attr_accessor w: Integer?
        def m: () -> Integer?
        def touch: () -> void
        def set_r: (Integer? v) -> void
      end

      class SubHolder < Holder
      end

      class Overridden < Holder
      end

      class Base2
        attr_reader r: Integer?
      end

      class Sub2 < Base2
      end

      class Account
        %a{rigor:v1:predicate-if-true self is Admin}
        attr_reader admin: bool?
      end

      class Admin < Account
        def grant: () -> void
      end

      class Job
        attr_accessor done: true?
      end

      class HDm
        attr_reader r: Integer?
      end

      class HRef
        attr_reader r: Integer?
      end

      class HSing
        attr_reader r: Integer?
      end

      class Sink
        def int: (Integer n) -> void
        def node: (::Prism::Node n) -> void
      end

      class Probe
        @x: Holder
        @task: Job
        def initialize: (Holder x, Job t) -> void
        def f: (Holder x, Sink s, ?Holder y) -> void
        def f3: (Holder x, Sink s, Array[Integer] items) -> void
        def f4: (Holder x, Sink s, ?Holder y) -> void
        def f5: (Holder x, Sink s, ?Holder y) -> void
        def iv: (Sink s) -> void
        def iv2: (Sink s) -> void
        def reset!: () -> void
        def dm: (HDm x, Holder h, Sink s) -> void
        def rf: (HRef x, Holder h, Sink s) -> void
        def sg: (HSing x, Holder h, Sink s) -> void
        def jb: (Job j, Job k) -> Integer
        def jb2: (Job j) -> Integer
        def jb3: () -> Integer
        def jctl: () -> Integer
        def reset_all: (Array[Job] js) -> void
        def f2: (Holder x, Sink s, ?Holder y) -> void
        def g: (Holder? x, Sink s) -> void
        def g2: (Holder? x, Sink s) -> void
        def h: (SubHolder x, Sink s) -> void
        def o: (Overridden x, Sink s) -> void
        def b: (Base2 x, Sink s) -> void
        def pr: (::Prism::CallNode x, Sink s) -> void
        def pr2: (::Prism::CallNode x, Sink s) -> void
        def pr3: (::Prism::CallNode x, Sink s) -> void
        def prs: (Array[::Prism::CallNode] xs, Sink s) -> void
        def mutate: (Holder x) -> void
        def ac: (Account x) -> void
      end
    RBS
  end

  def diagnostics(body, extra: "")
    source = "#{extra}class Probe\n#{body.gsub(/^/, '  ')}end\n"
    analyze(source, sig: { "probe.rbs" => sig }).diagnostics
  end

  # `[line, rule]` of every mismatch and possible-nil-receiver, lines counted from the `class Probe` line (1).
  def findings(body, extra: "")
    offset = extra.count("\n")
    diagnostics(body, extra: extra)
      .select { |d| %w[call.argument-type-mismatch call.possible-nil-receiver].include?(d.rule.to_s) }
      .map { |d| [d.line - offset, d.rule.to_s] }
  end

  def fired(body, rule, extra: "")
    offset = extra.count("\n")
    source = "#{extra}class Probe\n#{body.gsub(/^/, '  ')}end\n"
    result = analyze(source, sig: { "probe.rbs" => sig }, config: { "severity_profile" => "strict" })
    result.diagnostics.select { |d| d.rule.to_s == rule }.map { |d| d.line - offset }
  end

  def dumps(body)
    diagnostics(body).select { |d| d.rule.to_s == "dump.type" }.map(&:message)
  end

  describe "guard shapes that narrow the re-read" do
    it "narrows after `return unless x.r`" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          return unless x.r
          s.int(x.r)
        end
      RUBY
    end

    it "narrows in the truthy arm of `if`, a ternary and `&&`" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          if x.r then s.int(x.r) end
          x.r ? s.int(x.r) : nil
          x.r && s.int(x.r)
        end
      RUBY
    end

    it "narrows after `return if x.r.nil?` and inside `unless x.r.nil?`" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          unless x.r.nil?
            s.int(x.r)
          end
          return if x.r.nil?
          s.int(x.r)
        end
      RUBY
    end

    it "narrows an attribute an RBS superclass declares" do
      expect(findings(<<~RUBY)).to eq([])
        def h(x, s)
          return unless x.r
          s.int(x.r)
        end
      RUBY
    end

    # The narrowing of a nilable `x` comes from the pre-existing `&.` receiver rules; the chain fact is added on top.
    it "narrows both `x` and the re-read after `return unless x&.r` and `return if x&.r.nil?`" do
      expect(findings(<<~RUBY)).to eq([])
        def g(x, s)
          return unless x&.r
          s.int(x.r)
        end

        def g2(x, s)
          return if x&.r.nil?
          s.int(x.r)
        end
      RUBY
    end

    it "carries into a block body entered after the guard, and past a block that does not mention the root" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          return unless x.r
          [1].each { s.int(x.r) }
        end

        def f2(x, s, y = nil)
          return unless x.r
          [1].each { |i| i }
          s.int(x.r)
        end
      RUBY
    end

    it "carries into a loop body entered after the guard" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          return unless x.r
          while rand > 0.5
            s.int(x.r)
          end
        end
      RUBY
    end
  end

  describe "edges the guard already had" do
    # The attribute's `RBS::Extended` predicate fact narrows `x` to `Admin`; the chain fact is added beside it.
    it "keeps an RBS::Extended predicate fact the attribute carries" do
      result = diagnostics(<<~RUBY)
        def ac(x)
          if x.admin
            Rigor.dump_type(x.admin)
            x.grant
          end
        end
      RUBY
      expect(result.map { |d| [d.rule.to_s, d.message] }).to eq([["dump.type", "dump_type: true"]])
    end
  end

  describe "the edge that does not remove nil" do
    # The falsey arm keeps the declared `Integer?`, so a later test of the reader there is not folded to a constant.
    it "leaves the falsey arm of a truthiness guard at the declared type and narrows the truthy one" do
      expect(dumps(<<~RUBY)).to eq(["dump_type: Integer?", "dump_type: Integer"])
        def f(x, s, y = nil)
          unless x.r
            Rigor.dump_type(x.r)
          else
            Rigor.dump_type(x.r)
          end
        end
      RUBY
    end
  end

  describe "invalidation" do
    # Guard (fails without the rebind rule in `Scope#bind_local`).
    it "does not narrow after the root is rebound" do
      expect(findings(<<~RUBY)).to eq([[5, "call.argument-type-mismatch"]])
        def f(x, s, y = nil)
          return unless x.r
          x = y
          s.int(x.r)
        end
      RUBY
    end

    # Guard (fails without `IndexedNarrowing.invalidate_chain_after_call`).
    it "does not narrow after another call on the root" do
      expect(findings(<<~RUBY)).to eq([[5, "call.argument-type-mismatch"]])
        def f(x, s, y = nil)
          return unless x.r
          x.touch
          s.int(x.r)
        end
      RUBY
    end

    # Guard (fails without `IndexedNarrowing.invalidate_chain_after_call`).
    it "does not narrow after the attr_accessor writer runs" do
      expect(findings(<<~RUBY)).to eq([[5, "call.argument-type-mismatch"]])
        def f(x, s, y = nil)
          return unless x.w
          x.w = nil
          s.int(x.w)
        end
      RUBY
    end

    it "does not narrow after a compound write of the attribute" do
      expect(findings(<<~RUBY)).to eq([[5, "call.argument-type-mismatch"], [11, "call.argument-type-mismatch"]])
        def f(x, s, y = nil)
          return unless x.w
          x.w &&= nil
          s.int(x.w)
        end

        def f2(x, s, y = nil)
          return unless x.w
          x.w += 1
          s.int(x.w)
        end
      RUBY
    end

    # `f5` is a class guard, whose narrowing the same writes end.
    it "does not narrow after a multiple assignment or a for loop writes the attribute" do
      expect(findings(<<~RUBY)).to eq((0..2).map { |i| [5 + (i * 6), "call.argument-type-mismatch"] })
        def f3(x, s, items)
          return unless x.w
          x.w, _y = nil, 1
          s.int(x.w)
        end

        def f4(x, s, y = nil)
          return unless x.w
          for x.w in [nil] do end
          s.int(x.w)
        end

        def f5(x, s, y = nil)
          return unless x.w.is_a?(Integer)
          x.w, _y = nil, 1
          s.int(x.w)
        end
      RUBY
    end

    it "does not narrow after a call whose block mentions the root" do
      expect(findings(<<~RUBY)).to eq([[5, "call.argument-type-mismatch"], [11, "call.argument-type-mismatch"]])
        def f3(x, s, items)
          return unless x.w
          items.each { x.w = nil }
          s.int(x.w)
        end

        def f(x, s, y = nil)
          return unless x.w
          1.tap { x.w = nil }
          s.int(x.w)
        end
      RUBY
    end

    it "does not narrow after a call that runs a lambda" do
      expect(findings(<<~RUBY)).to eq([[6, "call.argument-type-mismatch"], [13, "call.argument-type-mismatch"]])
        def f(x, s, y = nil)
          clear = -> { x.w = nil }
          return unless x.w
          clear.call
          s.int(x.w)
        end

        def f2(x, s, y = nil)
          clear = -> { x.w = nil }
          return unless x.w
          clear.()
          s.int(x.w)
        end
      RUBY
    end

    it "does not narrow an instance-variable root after an implicit-self call, and narrows it with none" do
      expect(findings(<<~RUBY)).to eq([[10, "call.argument-type-mismatch"]])
        def initialize(x, t)
          @x = x
          @task = t
        end

        def iv(s)
          return unless @x.r
          reset!
          s.int(@x.r)
        end

        def iv2(s)
          return unless @x.r
          s.int(@x.r)
        end

        def reset!
          @x.set_r(nil)
        end
      RUBY
    end

    # The extra invalidation is for attribute-chain facts only: an `is_a?` fact on a reader declared with `def` keeps
    # its own rules, which a block mentioning the root does not end.
    it "leaves an is_a? fact on a def reader to the class guard's rules" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          return unless x.m.is_a?(Integer)
          [1].each { x }
          s.int(x.m)
        end
      RUBY
    end

    # Known limit, inherited from the `is_a?` chain rule: passing `x` to another method is not a call on `x`, so the
    # fact survives although the callee may write the attribute (Ruby: `mutate(h)` that calls `h.set_r(nil)` makes
    # `h.r` nil). The second method shows the `is_a?` guard behaving the same way.
    it "keeps the narrowing when the root is only passed as an argument, as the is_a? chain does" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          return unless x.r
          mutate(x)
          s.int(x.r)
        end

        def f2(x, s, y = nil)
          return unless x.r.is_a?(Integer)
          mutate(x)
          s.int(x.r)
        end
      RUBY
    end

    # Known limit, inherited from the `is_a?` chain rule: a write through another variable holding the same object
    # (Ruby: `y = x; y.w = nil` makes `x.w` nil) is a call on `y`, not on `x`.
    it "keeps the narrowing across a write through an alias of the root" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          y = x
          return unless x.w
          y.w = nil
          s.int(x.w)
        end
      RUBY
    end
  end

  # The fact never proves a check redundant, so a wrong narrowing costs a missed report at most. `jctl` is the
  # positive control: an ordinary always-true condition in the same file still fires.
  describe "flow.always-truthy-condition" do
    it "does not fire on a re-test whose constancy rests on an attribute-chain fact" do
      expect(fired(<<~RUBY, "flow.always-truthy-condition")).to eq([16])
        def jb(j, k)
          return 0 unless j.done
          k.done = nil
          if j.done then 1 else 2 end
        end

        def jb2(j)
          return 0 unless j.done
          reset_all([j])
          if j.done then 1 else 2 end
        end

        def jctl
          t = 1 == 1
          if t then 1 else 2 end
        end

        def reset_all(js)
          js.each { |job| job.done = nil }
        end
      RUBY
    end

    it "does not fire on a re-test of an instance-variable attribute after an implicit-self call" do
      expect(fired(<<~RUBY, "flow.always-truthy-condition")).to eq([19])
        def initialize(x, t)
          @x = x
          @task = t
        end

        def jb3
          return 0 unless @task.done
          reset!
          if @task.done then 1 else 2 end
        end

        def reset!
          @task.done = nil
        end

        def jctl
          t = 1 == 1
          if t then 1 else 2 end
        end
      RUBY
    end
  end

  describe "readers that are not stored attributes" do
    it "does not narrow a reader the RBS declares with def (control)" do
      expect(findings(<<~RUBY)).to eq([[4, "call.argument-type-mismatch"], [9, "call.argument-type-mismatch"]])
        def f(x, s, y = nil)
          return unless x.m
          s.int(x.m)
        end

        def f2(x, s, y = nil)
          return if x.m.nil?
          s.int(x.m)
        end
      RUBY
    end

    it "does not narrow an RBS attribute the receiver's own project class redefines with def" do
      extra = "class Overridden < Holder\n  def r = rand > 0.5 ? 1 : nil\nend\n"
      expect(findings(<<~RUBY, extra: extra)).to eq([[4, "call.argument-type-mismatch"]])
        def o(x, s)
          return unless x.r
          s.int(x.r)
        end
      RUBY
    end

    it "does not narrow an RBS attribute a project subclass of the receiver's class redefines with def" do
      extra = "class Sub2 < Base2\n  def r = rand > 0.5 ? 1 : nil\nend\n"
      expect(findings(<<~RUBY, extra: extra)).to eq([[4, "call.argument-type-mismatch"]])
        def b(x, s)
          return unless x.r
          s.int(x.r)
        end
      RUBY
    end
  end

  # Each example carries a same-file control: `h.w` on `Holder`, whose `w` nothing redefines, still narrows.
  describe "attributes the project may answer another way" do
    it "does not narrow an attribute a define_method on the receiver's class answers" do
      extra = "class HDm\n  define_method(:r) { rand > 0.5 ? 1 : nil }\nend\n"
      expect(findings(<<~RUBY, extra: extra)).to eq([[4, "call.argument-type-mismatch"]])
        def dm(x, h, s)
          return unless x.r
          s.int(x.r)
          return unless h.w
          s.int(h.w)
        end
      RUBY
    end

    # Conservative by name: any `define_method(:r)` in the project withholds the rule for every `r`.
    it "does not narrow an attribute whose name a define_method on another class defines" do
      extra = "class Unrelated\n  define_method(:r) { 1 }\nend\n"
      expect(findings(<<~RUBY, extra: extra)).to eq([[4, "call.argument-type-mismatch"]])
        def f(x, s, h = nil)
          return unless x.r
          s.int(x.r)
          return unless x.w
          s.int(x.w)
        end
      RUBY
    end

    it "does not narrow an attribute a refinement redefines" do
      extra = "module FlakyRef\n  refine HRef do\n    def r = nil\n  end\nend\nusing FlakyRef\n"
      expect(findings(<<~RUBY, extra: extra)).to eq([[4, "call.argument-type-mismatch"]])
        def rf(x, h, s)
          return unless x.r
          s.int(x.r)
          return unless h.w
          s.int(h.w)
        end
      RUBY
    end

    # Ruby: `def obj.r = nil` on a `Holder` makes that object's `r` nil.
    it "does not narrow an attribute a singleton def on some object redefines" do
      extra = "obj = Holder.new\ndef obj.r = nil\n"
      expect(findings(<<~RUBY, extra: extra)).to eq([[4, "call.argument-type-mismatch"]])
        def f(x, s, h = nil)
          return unless x.r
          s.int(x.r)
          return unless x.w
          s.int(x.w)
        end
      RUBY
    end

    it "does not narrow an attribute of a class whose body defines singleton methods" do
      extra = "class HSing\n  def initialize = define_singleton_method(:r) { nil }\nend\n"
      expect(findings(<<~RUBY, extra: extra)).to eq([[4, "call.argument-type-mismatch"]])
        def sg(x, h, s)
          return unless x.r
          s.int(x.r)
          return unless h.w
          s.int(h.w)
        end
      RUBY
    end
  end

  # The #2681 measurement's shape: a plugin hook's `call_node` typed `Prism::CallNode`, its nilable `receiver` guarded,
  # then passed where a `Prism::Node` is required. Prism's own RBS declares every node field with `attr_reader`.
  describe "Prism node readers" do
    it "narrows a guarded Prism::CallNode#receiver, with an unguarded read as the positive control" do
      expect(findings(<<~RUBY)).to eq([[18, "call.argument-type-mismatch"]])
        def pr(x, s)
          return unless x.receiver
          s.node(x.receiver)
        end

        def pr3(x, s)
          x.receiver ? s.node(x.receiver) : nil
        end

        def prs(xs, s)
          xs.each do |call_node|
            next nil unless call_node.receiver
            s.node(call_node.receiver)
          end
        end

        def pr2(x, s) = s.node(x.receiver)
      RUBY
    end
  end
end
