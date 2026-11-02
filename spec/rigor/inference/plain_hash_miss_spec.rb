# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #2555 L3, slice 2 — `h[k]` on a local Hash this body built with no default, which has not escaped, reads
# `V | nil` (`Inference::PlainHashMiss`), so an unguarded miss reports `call.possible-nil-receiver`. Every other
# receiver keeps `RbsDispatch`'s optimistic `V`. Each "reports nothing" example has the reporting shape as its
# control: the first example below, which differs from it only in the line under test.
RSpec.describe "plain Hash miss on an engine-built local (issue #2555)", type: :runner do
  def diagnostics(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
  end

  def nil_rules(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?("call.possible-nil", "call.undefined-method")
    end
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # The control every silent example below is read against.
  def expect_report(body)
    expect(nil_rules(body)).to eq(["call.possible-nil-receiver"])
  end

  def expect_silent(body)
    expect(nil_rules(body)).to be_empty
  end

  describe "a literal Hash the body built" do
    it "reads a computed key as V | nil and reports the unguarded miss" do
      expect(dumped_types(<<~RUBY)).to eq(['"x"?'])
        def m(k, s)
          h = { s => "x" }
          dump_type(h[k])
        end
      RUBY
      expect_report(<<~RUBY)
        def m(k, s)
          h = { s => "x" }
          v = h[k]
          v.upcase
        end
      RUBY
    end

    it "reports on an empty literal filled by a store" do
      expect_report(<<~RUBY)
        def m(k)
          h = {}
          h[:a] = "x"
          v = h[k]
          v.upcase
        end
      RUBY
    end

    it "keeps a proven key on a closed shape nil-free" do
      expect_silent(<<~RUBY)
        def m
          h = { a: "x" }
          v = h[:a]
          v.upcase
        end
      RUBY
    end
  end

  describe "a guarded read" do
    {
      "safe navigation" => "v = h[k]\n  v&.upcase",
      "a truthy assignment guard" => "if (v = h[k])\n    v.upcase\n  end",
      "an `or return` guard" => "v = h[k] or return\n  v.upcase",
      "`fetch`" => "v = h.fetch(k)\n  v.upcase",
      "a `key?` guard on the same receiver and key" => "if h.key?(k)\n    v = h[k]\n    v.upcase\n  end"
    }.each do |label, body|
      it "reports nothing under #{label}" do
        expect_silent(<<~RUBY)
          def m(k, s)
            h = { s => "x" }
            #{body}
          end
        RUBY
      end
    end
  end

  # `Hash.new { }` and `replace` are guards: both read `Dynamic[top]` today, so they stay quiet with or without the
  # `:defaulted` stamp; the stamp keeps them quiet once their values are typed.
  describe "a Hash that may answer a miss with a default" do
    {
      "`Hash.new(0)`" => ["h = Hash.new(0)", "v + 1"],
      "`Hash.new { }`" => ["h = Hash.new { |hh, kk| hh[kk] = [] }", "v << 1"],
      "a later `default=`" => ["h = { s => 1 }\n  h.default = 0", "v + 1"],
      "a later `default_proc=`" => ["h = { s => 1 }\n  h.default_proc = proc { 0 }", "v + 1"],
      "a later `replace`" => ["h = { s => 1 }\n  h.replace(Hash.new(0))", "v + 1"]
    }.each do |label, (build, use)|
      it "keeps the optimistic V after #{label}" do
        expect_silent(<<~RUBY)
          def m(k, s)
            #{build}
            v = h[k]
            #{use}
          end
        RUBY
      end
    end

    it "leaves a gradual value side without the nil" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        def m(k, s, t)
          h = { s => t }
          dump_type(h[k])
        end
      RUBY
    end

    it "keeps a store on Hash.new(0) in the value side (the master false positive)" do
      expect(nil_rules(<<~RUBY)).to be_empty
        def m
          h = Hash.new(0)
          h[:y] = "s"
          h[:y].upcase
        end
      RUBY
      expect(dumped_types(<<~RUBY)).to eq(["Integer | String", "Integer"])
        def m
          h = Hash.new(0)
          h[:y] = "s"
          dump_type(h[:y])
          c = Hash.new(0)
          c[:x] += 1
          dump_type(c[:x])
        end
      RUBY
    end

    it "keeps the optimistic V when either arm of a join has a default, and reports when neither does" do
      expect_silent(<<~RUBY)
        def m(c, k, s)
          if c
            h = { s => "x" }
          else
            h = Hash.new("d")
          end
          v = h[k]
          v.upcase
        end
      RUBY
      expect_report(<<~RUBY)
        def m(c, k, s)
          if c
            h = { s => "x" }
          else
            h = { s => "y" }
          end
          v = h[k]
          v.upcase
        end
      RUBY
    end
  end

  describe "a receiver whose construction the body does not vouch for" do
    {
      "an escaped local" => "h = { s => \"x\" }\n  foo(h)\n  v = h[k]",
      "a parameter" => "h = param\n  v = param[k]",
      "an instance variable" => "@h = { s => \"x\" }\n  v = @h[k]",
      "a constant" => "v = MAP[k]",
      "a local filled in a block" => "h = {}\n  [s].each { |x| h[x] = \"x\" }\n  v = h[k]",
      "a local read through `||=`" => "h = { s => \"x\" }\n  h[k] ||= \"y\"\n  v = h[k]",
      "a Hash subclass" => "h = MyHash.new\n  h[s] = \"x\"\n  v = h[k]"
    }.each do |label, body|
      it "keeps the optimistic V on #{label}" do
        expect_silent(<<~RUBY)
          MAP = { ENV.fetch("A") => "x" }.freeze
          class MyHash < Hash; end
          def foo(_) = nil
          def m(k, s, param)
            #{body}
            v.upcase
          end
        RUBY
      end
    end

    it "keeps the optimistic V when the project defines a method named `[]`" do
      expect_silent(<<~RUBY)
        class Box
          def [](_key) = 1
        end
        def m(k, s)
          h = { s => "x" }
          v = h[k]
          v.upcase
        end
      RUBY
    end
  end

  describe "the optimistic mark" do
    let(:hash_type) do
      Rigor::Type::Combinator.nominal_of(
        "Hash", type_args: [Rigor::Type::Combinator.nominal_of("Symbol"), Rigor::Type::Combinator.constant_of("x")]
      )
    end

    def evaluate(base)
      base.evaluate(Prism.parse("v = h[key]", scopes: [%i[h key]]).value)
    end

    it "is not recorded for the carve-out's read, and is for the same read without the fact" do
      base = Rigor::Scope.empty.with_local(:h, hash_type).with_local(:key, Rigor::Type::Combinator.untyped)
      type, plain = evaluate(base.with_construction_fact(:h, :synthesised))
      expect(type.describe).to eq('"x"?')
      expect(plain.optimistic_local(:v)).to be_nil

      type, declared = evaluate(base)
      expect(type.describe).to eq('"x"')
      expect(declared.optimistic_local(:v)).not_to be_nil
    end
  end
end
