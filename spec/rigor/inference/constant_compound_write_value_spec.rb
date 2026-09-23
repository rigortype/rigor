# frozen_string_literal: true

require "spec_helper"

# Issue #617's compound-write rule, extended to constant targets. A constant compound write evaluates to the value
# it stores, which is a function of the constant's CURRENT binding: `H ||= 0` on a bound, truthy `H` is `H` itself.
# Typed as the rvalue alone, `v = (H ||= 0); v[:x]` reported `Integer#[]` on a program whose `v[:x]` is `1`.
#
# The current binding is what a plain read of the constant resolves to at the write site. Every bound example is
# paired with an UNBOUND control — nothing the analyzer saw binds the constant — where a `||=` / `&&=` keeps the
# ADR-5 optimistic rvalue reading the memoization idiom relies on, exactly as a variable target does.
RSpec.describe "constant compound write value", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def dumped_type(source) = dumped_types(source).first

  def call_rules(source)
    result = analyze(source)
    result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("call.") }
  end

  describe "a bound bare constant" do
    it "types `||=` as the stored value, not the rvalue alone" do
      # Runtime: `v` is `H` itself.
      expect(dumped_type(<<~RUBY)).to eq("0 | { x: 1 }")
        H = { x: 1 }
        v = (H ||= 0)
        dump_type(v)
      RUBY
    end

    it "no longer reports a call on the value the `||=` returns" do
      expect(call_rules(<<~RUBY)).to be_empty
        H = { x: 1 }
        v = (H ||= 0)
        v[:x]
      RUBY
    end

    it "no longer folds a `||=` block tail to the rvalue at every position" do
      # Runtime: every value is `F` itself; the fold answered `{ x: 0, y: 0 }`.
      expect(dumped_type(<<~RUBY)).to eq("{ x: 0 | { x: 1, y: 2 }, y: 0 | { x: 1, y: 2 } }")
        F = { x: 1, y: 2 }
        f = F
        dump_type(f.transform_values { |e| F ||= 0 })
      RUBY
    end

    it "types `&&=` as the stored value" do
      # Runtime: `nil` — the constant is falsey, so nothing is stored.
      expect(dumped_type(<<~RUBY)).to eq(%("s"?))
        FLAG = nil
        dump_type(FLAG &&= "s")
      RUBY
    end

    it "types an operator write as the operator dispatched on the binding" do
      # Runtime: `2`, with an already-initialized-constant warning.
      expect(dumped_type(<<~RUBY)).to eq("2")
        COUNT = 1
        dump_type(COUNT += 1)
      RUBY
    end

    it "resolves the binding through the lexical nesting a plain read takes" do
      # Runtime: `3`.
      expect(dumped_type(<<~RUBY)).to eq("3 | 9")
        class Holder
          LIMIT = 3
          dump_type(LIMIT ||= 9)
        end
      RUBY
    end

    it "still folds `||=` to the rvalue when the binding is provably falsey" do
      # Runtime: `1`.
      expect(dumped_type(<<~RUBY)).to eq("1")
        UNSET = nil
        dump_type(UNSET ||= 1)
      RUBY
    end
  end

  describe "a bound constant path" do
    it "types `||=` as the stored value" do
      # Runtime: `10`.
      expect(dumped_type(<<~RUBY)).to eq(%("x" | 10))
        module Conf
          LIMIT = 10
        end
        dump_type(Conf::LIMIT ||= "x")
      RUBY
    end

    it "types `&&=` as the stored value" do
      # Runtime: `nil`.
      expect(dumped_type(<<~RUBY)).to eq(%("x"?))
        module Conf
          OFF = nil
        end
        dump_type(Conf::OFF &&= "x")
      RUBY
    end

    it "types an operator write as the operator dispatched on the binding" do
      # Runtime: `11`.
      expect(dumped_type(<<~RUBY)).to eq("11")
        module Conf
          LIMIT = 10
        end
        dump_type(Conf::LIMIT += 1)
      RUBY
    end

    it "reads a rooted path at the top level" do
      # Runtime: `{ a: 1 }`.
      expect(dumped_type(<<~RUBY)).to eq("0 | { a: 1 }")
        ROOT = { a: 1 }
        module Mod
          dump_type(::ROOT ||= 0)
        end
      RUBY
    end

    it "keeps a `||=` whose rvalue is a guard on the binding" do
      # Runtime: `{ a: 1 }`; the `raise` never runs.
      expect(dumped_type(<<~RUBY)).to eq("{ a: 1 }")
        SETTINGS = { a: 1 }
        dump_type(SETTINGS ||= raise("boot first"))
      RUBY
    end
  end

  describe "an unbound constant (controls)" do
    it "keeps the memoizing `||=` on the rvalue" do
      # Runtime: `"s"`. Nothing wrote the constant, so the stored value is the rvalue.
      expect(dumped_type(%(dump_type(MEMO_ONLY ||= "s")))).to eq(%("s"))
    end

    it "keeps a memoizing `||=` inside a method body on the rvalue" do
      # `X ||= v` is legal in a `def` body (only a plain `X = v` is a dynamic constant assignment).
      expect(dumped_type(<<~RUBY)).to eq(%("s"))
        def registry = dump_type(REGISTRY_ONLY ||= "s")
      RUBY
    end

    it "keeps a memoizing path `||=` on the rvalue" do
      expect(dumped_type(<<~RUBY)).to eq(%("s"))
        module Conf; end
        dump_type(Conf::MEMO_ONLY ||= "s")
      RUBY
    end

    it "keeps an unbound `&&=` on the rvalue, as a variable target does" do
      expect(dumped_type("dump_type(AND_ONLY &&= 1)")).to eq("1")
    end

    it "reads an unbound operator write as Dynamic[top], as a variable target does" do
      # Runtime: NameError. The rvalue alone is never the value; the binding is somewhere the analyzer did not see.
      expect(dumped_type("dump_type(COUNT_ONLY += 1)")).to eq("Dynamic[top]")
    end

    it "reads a path whose base has no static name as unbound" do
      # Runtime: `"s"` for a `Box` with no `ITEM`, and NameError for the operator write.
      expect(dumped_types(<<~RUBY)).to eq([%("s"), "Dynamic[top]"])
        def put(klass) = dump_type(klass::ITEM ||= "s")
        def bump(klass) = dump_type(klass::COUNT += 1)
      RUBY
    end

    it "reads an unbound `||=` guard as the binding it guards, not the rvalue's bot" do
      # `SETTINGS_ONLY ||= raise ...` returns only when something the analyzer did not see set the constant.
      expect(dumped_type(%(dump_type(SETTINGS_ONLY ||= raise("boot first"))))).to eq("Dynamic[top]")
    end

    it "does not bind a top-level memo to a constant of the namespace that calls it" do
      # Runtime: `{}`. Ruby resolves the top-level `def`'s `REGISTRY` at the top level, which is unset there;
      # `Plugin::REGISTRY` is the caller's, and the lexical ladder's caller-derived rungs must not supply it.
      expect(dumped_type(<<~RUBY)).to eq("{}")
        def registry = (REGISTRY ||= {})

        class Plugin
          REGISTRY = "plugins"

          def entries = dump_type(registry)
        end
      RUBY
    end
  end

  describe "a meta-new class under `||=` (issue #963)" do
    it "reads the class the first write names as the binding of a later one" do
      # Runtime: `Line`, the first struct. The class the meta-new write declares is the binding.
      expect(dumped_type(<<~RUBY)).to eq("Struct.new(:other) | singleton(Line)")
        Line ||= Struct.new(:text) do
          def hi = text
        end
        dump_type(Line ||= Struct.new(:other))
      RUBY
    end
  end
end
