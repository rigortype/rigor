# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 WD5 — `class_cvars` is the first discovery table built by a {DeclarationWalk} collector. The walker it
# replaced stays as the oracle (`legacy_class_cvar_index`), and these sources drive every arm that walker had
# through both: `class <<`, every meta-new write spelling (`.freeze` tail, `||=`, `K = K || …`, `self::K =`),
# bare factory blocks, the eval family with bare, `self`, `self::` and unnamed receivers, `def` barriers, and
# the unnameable cref a nameable header re-anchors. The corpus-scale half is `RIGOR_SHADOW_RULE_WALK=1`.
module ClassCvarsEquivalenceCases
  CASES = {
    "plain, nested, compact, rooted and singleton defs" => <<~RUBY,
      module Outer
        class Plain
          def a = (@@a = 1)
          def self.b = (@@b = "s")
        end
        class Admin::Compact
          def c = (@@c = :c)
        end
        class ::Rooted
          def d = (@@d = 1.0)
        end
      end
    RUBY
    "a class << self body, and bare and nameable headers below it" => <<~RUBY,
      class C
        class << self
          def e = (@@e = 1)
          class Bare
            def f = (@@f = 1)
          end
          class ::Anchored
            def g = (@@g = 1)
          end
          class C::Pathed
            def h = (@@h = 1)
          end
        end
      end
    RUBY
    "meta-new writes in every spelling, with self:: headers inside" => <<~RUBY,
      class C
        K = Class.new(Base) do
          def i = (@@i = 1)
          class self::Inner
            def j = (@@j = 1)
          end
        end
        S = Struct.new(:a) do
          def k = (@@k = 1)
        end.freeze
        M ||= Module.new do
          class self::Deep
            def l = (@@l = 1)
          end
        end
        G = G || Data.define(:x) do
          class self::Guarded
            def m = (@@m = 1)
          end
        end
        self::P = Class.new do
          class self::Q
            def n = (@@n = 1)
          end
        end
      end
    RUBY
    "bare factory blocks" => <<~RUBY,
      class C
        Class.new(Parent) do
          def o = (@@o = 1)
          class self::Lost
            def p = (@@p = 1)
          end
          class Named
            def q = (@@q = 1)
          end
        end
      end
    RUBY
    "eval-family blocks and their receivers" => <<~RUBY,
      class X; end
      module M
        class Y; end
        X.class_eval do
          def r = (@@r = 1)
          class self::Reopened
            def s = (@@s = 1)
          end
        end
        Y.module_exec do
          class self::Local
            def t = (@@t = 1)
          end
        end
        X.instance_eval { class self::Single; def u = (@@u = 1); end }
        class_eval { class self::Bare; def v = (@@v = 1); end }
        self::Z.class_exec { class self::W; def w = (@@w = 1); end }
        records.first.class_eval { class self::Opaque; def x = (@@x = 1); end }
      end
    RUBY
    "eval blocks under class << self and inside a factory" => <<~RUBY,
      class C
        class << self
          class_eval { class self::A; def y = (@@y = 1); end }
          X.class_eval { class self::B; def z = (@@z = 1); end }
        end
        Class.new do
          self.class_eval { class self::D; def aa = (@@aa = 1); end }
        end
      end
    RUBY
    "def barriers and operator writes" => <<~RUBY,
      class Census
        def ab
          @@ab = 1
          @@ab = nil
          def nested = (@@hidden = 1)
          Foo.class_eval { def inner = (@@inner = 1) }
        end
        def ac
          @@ac ||= []
          @@ac = [1, 2]
        end
      end
    RUBY
    "a body-less header and a block-argument class_eval" => <<~RUBY
      class Empty < Base; end
      module M
        X.class_eval(&block)
        def ae = (@@ae = 1)
      end
    RUBY
  }.freeze
end

RSpec.describe Rigor::Inference::ScopeIndexer do
  let(:shadow) { Rigor::Inference::DeclarationWalk::Shadow }

  around do |example|
    saved = ENV.fetch("RIGOR_SHADOW_RULE_WALK", nil)
    ENV.delete("RIGOR_SHADOW_RULE_WALK")
    example.run
  ensure
    saved.nil? ? ENV.delete("RIGOR_SHADOW_RULE_WALK") : ENV.store("RIGOR_SHADOW_RULE_WALK", saved)
  end

  def parse(source)
    Prism.parse(source).value
  end

  def tables(source, scope = Rigor::Scope.empty)
    root = parse(source)
    [described_class.legacy_class_cvar_index(root, scope), described_class.build_class_cvar_index(root, scope)]
  end

  def described(table)
    table.transform_values { |cvars| cvars.transform_values(&:describe) }
  end

  describe "class_cvars on the declaration walk" do
    ClassCvarsEquivalenceCases::CASES.each do |name, source|
      it "builds the legacy walker's table: #{name}" do
        legacy, walk = tables(source)
        expect(legacy).not_to be_empty
        expect(shadow.first_difference(legacy, walk, "")).to be_nil
      end
    end

    it "keys cvars by the lexical cref, re-anchored only at a header that still names its class" do
      cases = ClassCvarsEquivalenceCases::CASES
      # `C::C::Pathed` is wrong, pinned because the port reproduces the legacy walker: Ruby opens `C::Pathed`
      # (the header's `C` is the top-level class). Flip this when #1519 is fixed.
      expect(described(tables(cases["a class << self body, and bare and nameable headers below it"]).last))
        .to eq("C" => { :@@e => "1" }, "Anchored" => { :@@g => "1" }, "C::C::Pathed" => { :@@h => "1" })
      expect(tables(cases["meta-new writes in every spelling, with self:: headers inside"]).last.keys)
        .to eq(%w[C C::K::Inner C::M::Deep C::G::Guarded C::P::Q])
      expect(tables(cases["bare factory blocks"]).last.keys).to eq(%w[C C::Named])
      expect(tables(cases["eval-family blocks and their receivers"]).last.keys)
        .to eq(%w[M X::Reopened M::Y::Local X::Single M::Bare M::Z::W])
      expect(tables(cases["eval blocks under class << self and inside a factory"]).last.keys).to eq(%w[X::B])
      expect(described(tables(cases["def barriers and operator writes"]).last))
        .to eq("Census" => { :@@ab => "1?", :@@ac => "[1, 2]" })
    end

    it "types each rvalue under the chain the census scope carries" do
      # The census scope's chain is pushed at every header, the unnameable `class D` below `class <<`
      # included, so `Bar` inside `class ::E` resolves through `C::D` first. The ancestry nesting would not
      # push `C::D`; the census scope always has, and a move keeps it. That answer is wrong: `class D` there
      # opens `#<Class:C>::D`, and Ruby resolves the top-level `Bar`. Flip this when #1520 is fixed.
      source = <<~RUBY
        class C
          class << self
            class D
              class ::E
                def ad = (@@ad = Bar.new)
              end
            end
          end
        end
      RUBY
      empty = Rigor::Scope.empty
      classes = %w[Bar C::D::Bar].to_h { |name| [name, Rigor::Type::Combinator.singleton_of(name)] }
      scope = empty.with_discovery(empty.discovery.with(discovered_classes: classes))
      legacy, walk = tables(source, scope)
      expect(shadow.first_difference(legacy, walk, "")).to be_nil
      expect(described(walk)).to eq("E" => { :@@ad => "C::D::Bar" })
    end
  end

  describe "the shadow harness on class_cvars" do
    let(:source) { "class C\n  def m = (@@x = 1)\nend\n" }

    it "never runs the legacy walker while RIGOR_SHADOW_RULE_WALK is unset" do
      allow(described_class).to receive(:legacy_class_cvar_index).and_call_original
      expect(described_class.build_class_cvar_index(parse(source), Rigor::Scope.empty).keys).to eq(%w[C])
      expect(described_class).not_to have_received(:legacy_class_cvar_index)
    end

    it "raises through ScopeIndexer.index when the walk's table diverges" do
      ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
      forgetful = Class.new(described_class::ClassCvarsCollector) do
        def table = {}.freeze
      end
      allow(described_class::ClassCvarsCollector).to receive(:new).and_return(forgetful.new)
      scope = Rigor::Scope.empty.with_source_path("app/c.rb")
      expect { described_class.index(parse(source), default_scope: scope) }
        .to raise_error(Rigor::Inference::DeclarationWalk::Shadow::Divergence,
                        %r{discovery table `class_cvars` for app/c\.rb: the table: key "C" only in legacy})
    end

    it "stays silent under the flag when the tables agree" do
      ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
      program = parse(source)
      index = described_class.index(program, default_scope: Rigor::Scope.empty)
      expect(index[program].class_cvars_for("C").keys).to eq(%i[@@x])
    end
  end
end
