# frozen_string_literal: true

require "spec_helper"

# Issue #1256 — Ruby evaluates a call's receiver, then its arguments left to right, and a literal's elements in
# order, so a later operand reads what an earlier one wrote or mutated. Issue #1223 and PR #1296 threaded those
# effects into the scope AFTER the statement, but a later operand was still typed — and recorded into the per-node
# scope index the diagnostics read — from the scope the operands STARTED from: `puts(b.unshift("s"),
# b.first.upcase)` reported `upcase` on the literal's `1`, and `[n += 1, n += 1]` typed as `[1, 1]`.
#
# Each example is paired with a control in the same position whose earlier operand leaves the variable alone, and
# which must keep reporting (or keep the pre-write answer): without it, a seam that stopped typing later operands
# altogether would pass too.
RSpec.describe "later operands read the scope the earlier ones left", type: :runner do
  def diagnostics(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prefix)
    diagnostics(source).filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?(prefix) }
  end

  # Every `call.` rule but the toplevel-resolution one the `include Rigor::Testing` header draws.
  def receiver_rules(source)
    rules(source, "call.") - ["call.unresolved-toplevel"]
  end

  def flow_messages(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message[/condition is always \w+/] if diagnostic.rule.to_s.start_with?("flow.")
    end
  end

  describe "the per-node scope index under a later operand" do
    it "reads a call argument after an earlier argument's in-place mutation" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        b = [1]
        puts(b.unshift("s"), b.first.upcase)
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        b = [1]
        puts(b.dup, b.first.upcase)
      RUBY
    end

    it "reads an array element after an earlier element's in-place mutation" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        c = [1]
        x = [c.unshift("s"), c.first.upcase]
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        c = [1]
        x = [c.dup, c.first.upcase]
      RUBY
    end

    it "reads a call argument after an earlier argument's write" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        n = nil
        puts(n = "s", n.upcase)
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        n = nil
        puts(m = "s", n.upcase)
      RUBY
    end

    it "reads a later argument after a mutation nested in an earlier one" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        c = [1]
        puts([c.unshift("s")].size, c.first.upcase)
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        c = [1]
        puts([c.dup].size, c.first.upcase)
      RUBY
    end

    it "reads an element of a literal that is itself a later operand" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        n = 0
        c = [1]
        puts(n += 1, (x = [c.unshift("s"), c.first.upcase]))
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        n = 0
        c = [1]
        puts(n += 1, (x = [c.dup, c.first.upcase]))
      RUBY
    end

    it "reads a splatted argument after an earlier argument's write" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        n = nil
        puts(n = "s", *[n.upcase])
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        n = nil
        puts(m = "s", *[n.upcase])
      RUBY
    end

    it "records a later operand inside a block that a threaded operand runs" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        b = [1]
        puts([1].each { |_| puts(b.unshift("s"), b.first.upcase) })
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        b = [1]
        puts([1].each { |_| puts(b.dup, b.first.upcase) })
      RUBY
    end

    it "checks a call's own argument from the scope its receiver left" do
      expect(rules(<<~RUBY, "call.argument")).to be_empty
        def probe
          k = :s
          (k = 0; 5)[k]
        end
      RUBY
      expect(rules(<<~RUBY, "call.argument")).to eq(["call.argument-type-mismatch"])
        def probe
          k = :s
          (z = 0; 5)[k]
        end
      RUBY
    end

    # The arm runs after `expr` raised, before or after its writes, so the scope after the modifier nil-injects a
    # local `expr` first binds. The arm itself, and the modifier's value, keep reading it as they did before #1256
    # (ADR-5): the raise almost always comes after the write.
    it "does not read a `rescue` modifier's arm from the nil-injected join" do
      expect(receiver_rules(<<~RUBY)).to be_empty
        z = (Float(u = gets.to_s) rescue u.strip)
        x = (Integer(v = gets.to_s) rescue v)
        x.succ
      RUBY
      expect(receiver_rules(<<~RUBY)).to eq(%w[call.undefined-method call.possible-nil-receiver])
        u = nil
        z = (Float(gets.to_s) rescue u.strip)
        v = nil
        x = (Integer(gets.to_s) rescue v)
        x.succ
      RUBY
    end
  end

  describe "the value of a later operand" do
    it "types a later element after an earlier element's write, and each write from its own entry" do
      expect(dumped_types(<<~RUBY)).to eq(["[1, 2]"])
        n = 0
        pair = [n += 1, n += 1]
        dump_type(pair)
      RUBY
      expect(dumped_types(<<~RUBY)).to eq(["[1, 1]"])
        n = 0
        pair = [n + 1, n + 1]
        dump_type(pair)
      RUBY
    end

    # `pair.last == 2` is always true at runtime, so the fold is a true one; the defect was its direction.
    it "folds a comparison on a later element as the split statements do" do
      split = flow_messages(<<~RUBY)
        n = 0
        first = (n += 1)
        last = (n += 1)
        puts "two" if last == 2
        puts "three" if last == 3
      RUBY
      expect(split).to eq(["condition is always truthy", "condition is always falsey"])
      expect(flow_messages(<<~RUBY)).to eq(split)
        n = 0
        pair = [n += 1, n += 1]
        puts "two" if pair.last == 2
        puts "three" if pair.last == 3
      RUBY
    end

    it "types an element read after an earlier element's in-place mutation" do
      expect(rules(<<~RUBY, "call.undefined")).to be_empty
        d = [1]
        y = [d.unshift("s"), d.first]
        y[1].upcase
      RUBY
      expect(rules(<<~RUBY, "call.undefined")).to eq(["call.undefined-method"])
        d = [1]
        y = [d.dup, d.first]
        y[1].upcase
      RUBY
    end

    it "passes a later argument's post-write type to the callee" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        def second(_a, b) = b
        a = :init
        r = second(a = 1, a)
        dump_type(r)
      RUBY
      expect(dumped_types(<<~RUBY)).to eq([":init"])
        def second(_a, b) = b
        a = :init
        r = second(z = 1, a)
        dump_type(r)
      RUBY
    end

    it "types a hash value after an earlier value's write" do
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1, b: 1 }"])
        g = :init
        h = { a: (g = 1), b: g }
        dump_type(h)
      RUBY
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1, b: :init }"])
        g = :init
        h = { a: (z = 1), b: g }
        dump_type(h)
      RUBY
    end

    it "passes an argument after a receiver's write to the callee" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        class W
          def id(x) = x
        end
        a = :init
        r = (a = 1; W.new).id(a)
        dump_type(r)
      RUBY
      expect(dumped_types(<<~RUBY)).to eq([":init"])
        class W
          def id(x) = x
        end
        a = :init
        r = (z = 1; W.new).id(a)
        dump_type(r)
      RUBY
    end

    it "passes a keyword argument after an earlier keyword's write to the callee" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        def kw(k: nil, b: nil) = b
        k = :init
        r = kw(k: (k = 1), b: k)
        dump_type(r)
      RUBY
      expect(dumped_types(<<~RUBY)).to eq([":init"])
        def kw(k: nil, b: nil) = b
        k = :init
        r = kw(k: (z = 1), b: k)
        dump_type(r)
      RUBY
    end

    it "passes a double splat after an earlier argument's write to the callee" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        def kw(_x, b: nil) = b
        hh = { b: :old }
        r = kw(hh = { b: 1 }, **hh)
        dump_type(r)
      RUBY
      expect(dumped_types(<<~RUBY)).to eq([":old"])
        def kw(_x, b: nil) = b
        hh = { b: :old }
        r = kw(z = { b: 1 }, **hh)
        dump_type(r)
      RUBY
    end
  end
end
