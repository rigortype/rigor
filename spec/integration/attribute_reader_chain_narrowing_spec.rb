# frozen_string_literal: true

require "spec_helper"

# Issue #2685 — a truthiness or `nil?` guard on `x.r` carries to the next `x.r` read when `r` is declared with
# `attr_reader` / `attr_accessor` in the RBS of the receiver's class or an RBS ancestor, and no project `def` can
# answer `r` instead. The fact is the single-hop method-chain narrowing `is_a?` guards already record, and is dropped
# by the same rules: a rebind of the root, or any later call on it.
#
# Each example passes the re-read to `Sink#int(Integer)`: a narrowed read is quiet, an un-narrowed one reports
# `call.argument-type-mismatch`. Ruby 4.0.5 behaviour the rule relies on, witnessed with `ruby -e`: two reads of an
# `attr_reader` with no write between return the same object; the writer `x.w = nil` and a method that sets the
# ivar through `x` passed as an argument both change the next read; `nil&.r` returns `nil` without calling `r`; and a
# subclass `def r` returns different values on two reads.
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

      class Sink
        def int: (Integer n) -> void
        def node: (::Prism::Node n) -> void
      end

      class Probe
        def f: (Holder x, Sink s, ?Holder y) -> void
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

    it "carries into a block body and a loop body entered after the guard" do
      expect(findings(<<~RUBY)).to eq([])
        def f(x, s, y = nil)
          return unless x.r
          [1].each { s.int(x.r) }
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
    # Guard: the falsey arm keeps the declared `Integer?`, so a later test of the reader is not folded.
    it "leaves the falsey arm of a truthiness guard at the declared type" do
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
