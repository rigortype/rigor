# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/protection/discovery_seed"
require_relative "../support/ruby_run"

# ADR-119 WD2 / WD5 (PR C1a) — the read-level witness for `Inference::DefinerResolution`, called directly (no
# production reader passes `settle`'s `unknown_for:` yet). Each fixture is a program with a conditional mixin
# (`include Q if ENV["Q"]`) that Ruby runs in BOTH worlds under the suite's own Ruby: the Ruby answer is what a
# sound read may say, and the read answers `Known` only where both worlds agree on it.
RSpec.describe Rigor::Inference::DefinerResolution do # rubocop:disable RSpec/SpecFilePathFormat
  let(:resolution) { described_class }

  def scope_for(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  # `expression`'s printed value in the world where `ENV["Q"]` is unset (`false`) or set (`true`).
  def ruby_says(source, expression, world, prelude: nil)
    program = "#{'ENV["Q"] = "1"' if world}\n#{source}\nputs(#{expression})\n"
    RubyRun.stdout(program, prelude: prelude).chomp
  end

  def both_worlds(source, expression, prelude: nil)
    [false, true].map { |world| ruby_says(source, expression, world, prelude: prelude) }
  end

  def resolve(scope, name, question: :definer, side: :instance, klass: "C")
    resolution.resolve(scope, klass, name, side, question: question)
  end

  def owner_of(result)
    case result
    in Rigor::Inference::DefinerResolution::Known(answer: _, owner:) then owner
    in Rigor::Inference::DefinerResolution::UNKNOWN then :unknown
    in Rigor::Inference::DefinerResolution::ABSENT then :absent
    end
  end

  describe "a named mark Q cannot answer the name" do
    let(:source) do
      <<~RUBY
        module Q; def bar = 1; end
        class Base; def foo = 1; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
    end

    it "is Known Base, where Ruby answers Base in both worlds" do
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Base])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq("Base")
    end

    it "is Unknown for the name Q does answer" do
      expect(both_worlds(source, "(C.instance_method(:bar).owner rescue :none)")).to eq(%w[none Q])
      expect(owner_of(resolve(scope_for(source), :bar))).to eq(:unknown)
    end
  end

  describe "a multi-file mark" do
    def project_scope(files)
      Dir.mktmpdir("rigor-definer-resolution-") do |dir|
        paths = files.map do |name, source|
          File.join(dir, name).tap { |path| File.write(path, source) }
        end
        tables = Rigor::Protection::DiscoverySeed.discovery_tables(paths)
        base = Rigor::Scope.empty
        return base.with_discovery(base.discovery.with(**tables))
      end
    end

    let(:base) { "class Base; def foo = 1; end\nmodule Q; def bar = 1; end\nmodule R; def baz = 1; end\n" }

    it "is Known when at most one of the node's edges' closures records the name" do
      scope = project_scope("a.rb" => "#{base}class C < Base; include Q; end\n", "b.rb" => "class C; include R; end\n")
      expect(scope.discovery.discovered_class_sources.fetch("C").size).to eq(2)
      expect(owner_of(resolve(scope, :foo))).to eq("Base")
    end

    it "is Unknown when two of them record it" do
      scope = project_scope("a.rb" => "#{base}module Q2; def foo = 2; end\nclass C < Base; include Q2; end\n",
                            "b.rb" => "module R2; def foo = 3; end\nclass C; include R2; end\n")
      expect(owner_of(resolve(scope, :foo))).to eq(:unknown)
    end
  end

  # WD2's five non-discharge shapes: each is a mark whose named entry could answer the name, so the read stays
  # Unknown. Ruby's answer is shown beside each, in both worlds.
  describe "the five non-discharge shapes" do
    it "declines when Q includes a module the project does not declare" do
      source = <<~RUBY
        module Q; include Ext; end
        class Base; def foo = 1; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      prelude = "module Ext; def foo = :ext; end\n"
      expect(both_worlds(source, "C.instance_method(:foo).owner", prelude: prelude)).to eq(%w[Base Ext])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end

    it "declines when Q's methods come from a define_method loop" do
      source = <<~RUBY
        module Q; [:foo].each { |name| define_method(name) { 2 } }; end
        class Base; def foo = 1; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Q])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end

    it "declines a visibility-only statement on the name asked" do
      source = <<~RUBY
        module Q; private :to_s; end
        class Base; def to_s = "base"; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.new.respond_to?(:to_s)")).to eq(%w[true false])
      expect(owner_of(resolve(scope_for(source), :to_s, question: :visibility))).to eq(:unknown)
    end

    it "declines when Q records method_missing" do
      source = <<~RUBY
        module Q; def method_missing(name, *) = 1; end
        class Base; def foo = 1; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Base])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end

    it "declines a mixin call the walk cannot record (`\"*\"`)" do
      source = <<~RUBY
        module X; def foo = 2; end
        class Base; def foo = 1; end
        class C < Base; send(:include, X) if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base X])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end
  end

  # A chain with a fork is never narrowed: relevance is argued for the fork-free case only.
  describe "a chain with a fork" do
    let(:header) do
      <<~RUBY
        module M; def foo = :m; end
        module X; def foo = :x; end
        module Q; def bar = 1; end
        class Base; include M; def foo = :base; end
      RUBY
    end

    # Ruby answers X#foo in both Q-worlds, so the answer is right and the read still declines. FLIP THIS if
    # relevance is extended to one-fork chains (ADR-119 WD2, "Why the rule stops at a fork").
    it "pins the one-fork witness (f3c) Unknown although Ruby answers X in both worlds" do
      source = "#{header}class C < Base; include M; include X; include Q if ENV[\"Q\"]; end\n"
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[X X])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end

    # Without X the answer is Base or M by load order: Unknown by the fork rule.
    it "is Unknown by the fork rule without X (f3b)" do
      source = "#{header}class C < Base; include M; include Q if ENV[\"Q\"]; end\n"
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Base])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end
  end

  # #1594 — the concern's `included do include A end` marks every includer's chain; A's closure records the name,
  # so the mark is not discharged and the migrated read declines where master answers `Base#foo`.
  describe "a concern's included block (#1594)" do
    let(:shim) do
      <<~RUBY
        module ActiveSupport
          module Concern
            def self.extended(base) = base.instance_variable_set(:@_included_block, nil)

            def included(base = nil, &block)
              if base.nil?
                @_included_block = block
              else
                super
                base.class_eval(&@_included_block) if @_included_block
              end
            end
          end
        end
      RUBY
    end
    let(:source) do
      <<~RUBY
        module M; def foo = "M"; end
        module A; include M; end
        module Concern
          extend ActiveSupport::Concern
          included do
            include A
          end
        end
        class Base; def foo = 1; end
        class C < Base; include Concern; end
        class Kc < Base; end
      RUBY
    end

    it "is Unknown through the drawn-on mark, and Known without the concern" do
      expect(RubyRun.stdout("#{source}p C.instance_method(:foo).owner\n", prelude: shim).chomp).to eq("M")
      scope = scope_for(source)
      expect(owner_of(resolve(scope, :foo))).to eq(:unknown)
      expect(owner_of(resolve(scope, :foo, klass: "Kc"))).to eq("Base")
    end
  end
end
