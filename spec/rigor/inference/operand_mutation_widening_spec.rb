# frozen_string_literal: true

require "spec_helper"

# An in-place mutator that is itself an OPERAND of another expression — the receiver of a chained call
# (`b.push(2).size`, `d.map!.with_index { … }`), an argument (`puts(b.push(2))`), a literal's element — widened
# nothing: `StatementEvaluator` typed an operand as a pure value unless it held a variable write or a jump, so the
# mutator's own post-call widening never ran and `b` kept the `[1]` its literal wrote. `d.first.upcase` after
# `d.map!.with_index { |x, i| x.to_s }` drew a false `call.undefined-method` for Integer.
#
# The contract is "exactly as the same call does as a statement", so each example compares against the
# statement form. Each is paired with a non-mutating control in the same position that must keep the literal —
# without it, a seam that widened every operand's receiver would pass too.
RSpec.describe "mutator widening in operand position", type: :runner do
  def diagnostics(source, sig: {})
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prefix)
    diagnostics(source).filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?(prefix) }
  end

  describe "a mutator that is the receiver of another call" do
    it "widens the variable as the statement form does" do
      statement = dumped_types(<<~RUBY)
        b = [1]
        b.push(2)
        dump_type(b)
      RUBY
      expect(statement).not_to eq(["[1]"])
      expect(dumped_types(<<~RUBY)).to eq(statement)
        b = [1]
        b.push(2).size
        dump_type(b)
      RUBY
    end

    it "keeps the literal under a non-mutating receiver call" do
      expect(dumped_types(<<~RUBY)).to eq(["[1]"])
        b = [1]
        b.dup.size
        dump_type(b)
      RUBY
    end

    it "widens an instance variable as the statement form does" do
      statement = dumped_types(<<~RUBY)
        class Box
          def fill
            @a = [1]
            @a.push(2)
            dump_type(@a)
          end
        end
      RUBY
      expect(statement).not_to eq(["[1]"])
      expect(dumped_types(<<~RUBY)).to eq(statement)
        class Box
          def fill
            @a = [1]
            @a.push(2).size
            dump_type(@a)
          end
        end
      RUBY
    end

    it "does not fold an arity check after a chained size-changing mutator" do
      expect(rules(<<~RUBY, "flow.")).to be_empty
        v = [1]
        v.push(2).size
        puts "one" if v.size == 1
      RUBY
      expect(rules(<<~RUBY, "flow.")).to eq(["flow.always-truthy-condition"])
        v = [1]
        v.dup.size
        puts "one" if v.size == 1
      RUBY
    end
  end

  describe "the enumerator form of a rewriting mutator (no block on the mutator itself)" do
    it "treats `map!.with_index` as the unknown store `map!` is" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]"])
        d = [1]
        d.map!.with_index { |x, i| x.to_s }
        dump_type(d)
      RUBY
      expect(rules(<<~RUBY, "call.undefined-method")).to be_empty
        d = [1]
        d.map!.with_index { |x, i| x.to_s }
        d.first.upcase
      RUBY
    end

    it "keeps the literal under the non-mutating `map.with_index`, whose element still fires" do
      expect(dumped_types(<<~RUBY)).to eq(["[1]"])
        d = [1]
        d.map.with_index { |x, i| x.to_s }
        dump_type(d)
      RUBY
      expect(rules(<<~RUBY, "call.undefined-method")).to eq(["call.undefined-method"])
        d = [1]
        d.map.with_index { |x, i| x.to_s }
        d.first.upcase
      RUBY
    end

    it "widens `collect!.each_with_index` and a filtering enumerator chain" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "Array[1 | 2]"])
        m = [1, 2]
        m.collect!.each_with_index { |x, i| x.to_s }
        dump_type(m)
        k = [1, 2]
        k.select!.with_index { |x, i| i > 0 }
        dump_type(k)
      RUBY
    end

    # The #561 boundary: a precise nominal is a declaration's claim, and the widening declines it in the
    # statement form, so it declines it here too.
    it "leaves a precise nominal as the statement form leaves it" do
      statement = dumped_types(<<~RUBY)
        a = gets.to_s.split(",")
        a.map! { |x| x.size }
        dump_type(a)
      RUBY
      expect(statement).to eq(["Array[String]"])
      expect(dumped_types(<<~RUBY)).to eq(statement)
        a = gets.to_s.split(",")
        a.map!.with_index { |x, i| x.size }
        dump_type(a)
      RUBY
    end
  end

  describe "a mutator in another operand position" do
    it "widens through an argument as the statement form does, and not through a non-mutating one" do
      statement = dumped_types(<<~RUBY)
        g = [1]
        g.push(2)
        dump_type(g)
      RUBY
      expect(dumped_types(<<~RUBY)).to eq(statement + ["[1]"])
        g = [1]
        puts(g.push(2))
        dump_type(g)
        h = [1]
        puts(h.first)
        dump_type(h)
      RUBY
    end

    it "widens through a literal's element and an interpolation" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Array[1] String])
        g = [1]
        x = [g.sort!]
        dump_type(g)
        s = +"a"
        y = "\#{s << "b"}"
        dump_type(s)
      RUBY
    end

    it "carries a block's mutation of a captured local out of a chained receiver" do
      statement = dumped_types(<<~RUBY)
        h = [1]
        [2, 3].each { |x| h << x }
        dump_type(h)
      RUBY
      expect(statement).not_to eq(["[1]"])
      expect(dumped_types(<<~RUBY)).to eq(statement)
        h = [1]
        [2, 3].each { |x| h << x }.size
        dump_type(h)
      RUBY
    end

    it "leaves a block parameter mutated inside an operand to the block" do
      expect(dumped_types(<<~RUBY)).to eq(["[1]"])
        z = [1]
        puts([[2]].map { |z| z << 1 }.size)
        dump_type(z)
      RUBY
    end
  end
end
