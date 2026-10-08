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
  let(:project_dirs) { [] }

  def scope_for(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  # The files stay on disk until the example ends: a declared module's body is read from them.
  def project_scope(files)
    dir = Dir.mktmpdir("rigor-definer-resolution-")
    project_dirs << dir
    paths = files.map do |name, source|
      File.join(dir, name).tap { |path| File.write(path, source) }
    end
    tables = Rigor::Protection::DiscoverySeed.discovery_tables(paths)
    base = Rigor::Scope.empty
    base.with_discovery(base.discovery.with(**tables))
  end

  after { project_dirs.each { |dir| FileUtils.rm_rf(dir) } }

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

  # WD2's non-discharge shapes (the `"*"` one twice, on the mark and inside Q's closure): each is a mark whose
  # named entry could answer the name, so the read stays
  # Unknown. Ruby's answer is shown beside each, in both worlds.
  describe "the non-discharge shapes" do
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
        module Q; def bar = 1; [:foo].each { |name| define_method(name) { 2 } }; end
        class Base; def foo = 1; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Q])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end

    it "declines when Q records the name only through a literal define_method" do
      source = <<~RUBY
        module Q; def bar = 1; define_method(:foo) { 2 }; end
        class Base; def foo = 1; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Q])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end

    it "declines when an RBS-known module in Q has the name, and discharges one whose declaration lacks it" do
      source = <<~RUBY
        module Q; def bar = 1; include Comparable; end
        class Base; def foo = 1; def between?(low, high) = false; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:between?).owner")).to eq(%w[Base Comparable])
      expect(owner_of(resolve(scope_for(source), :between?))).to eq(:unknown)
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Base])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq("Base")
    end

    it "declines a visibility-only statement on the name asked" do
      source = <<~RUBY
        module Q; def bar = 1; private :to_s; end
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

    it "declines when a module in Q's closure lists a mixin call the walk cannot record (`\"*\"`)" do
      source = <<~RUBY
        module X; def foo = 2; end
        module Q; def bar = 1; send(:include, X); end
        class Base; def foo = 1; end
        class C < Base; include Q if ENV["Q"]; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base X])
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

  # A hook defines the name on the includer with nothing the tables record on the module, so a closure holding
  # one cannot be said not to answer it.
  describe "a module whose hook adds the name to its includer" do
    def hooked(module_body, tail = 'include Q if ENV["Q"]')
      <<~RUBY
        #{module_body}
        class Base; def foo = 1; end
        class C < Base; #{tail}; end
      RUBY
    end

    {
      "included with attr_reader" => "module Q; def bar = 1; def self.included(b) = b.attr_reader(:foo); end",
      "included in `class << self`" =>
        "module Q; def bar = 1; class << self; def included(b) = b.send(:define_method, :foo) { 2 }; end; end",
      "append_features" =>
        "module Q; def bar = 1; def self.append_features(b) = (super; b.send(:define_method, :foo) { 2 }); end"
    }.each do |label, body|
      it "declines #{label}" do
        source = hooked(body)
        expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base C])
        expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
      end
    end

    it "declines a hook reached through the closure" do
      source = hooked(<<~RUBY)
        module X; def self.included(b) = b.send(:define_method, :foo) { 2 }; end
        module Q; def bar = 1; include X; end
      RUBY
      expect(both_worlds(source, "C.instance_method(:foo).owner")).to eq(%w[Base Q])
      expect(owner_of(resolve(scope_for(source), :foo))).to eq(:unknown)
    end
  end

  # `from:` is a position on the chain; the retro world must be read from the same entry.
  describe "from: on a chain with a retro world" do
    it "reads M after Base on both worlds" do
      source = <<~RUBY
        module M; def foo = :m; end
        module X; def foo = :x; end
        class Base; include M; def foo = :base; end
        class C < Base; include X; include M; end
      RUBY
      expect(RubyRun.stdout("#{source}p C.ancestors.first(4)\n").chomp).to eq("[C, X, Base, M]")
      scope = scope_for(source)
      chain = Rigor::Scope::ResolutionChain.for(scope, "C", :instance, :methods)
      after_base = chain.entries.index { |entry| entry.name == "Base" } + 1
      result = resolution.resolve(scope, "C", :foo, :instance, question: :definer, from: after_base)
      expect(owner_of(result)).to eq("M")
    end
  end

  # An external ancestor ahead of the candidate, or the implicit Object, may answer first.
  describe "external ancestors" do
    it "is Unknown where the implicit Object (Kernel) answers, Absent for a name nothing defines" do
      source = "class C; end\n"
      expect(RubyRun.stdout("#{source}p C.instance_method(:to_s).owner\n").chomp).to eq("Kernel")
      scope = scope_for(source)
      expect(owner_of(resolve(scope, :to_s))).to eq(:unknown)
      expect(owner_of(resolve(scope, :no_such_method_anywhere))).to eq(:absent)
    end

    it "is Unknown where an included external module answers ahead of the project definer" do
      source = "class Base; def between?(a, b) = false; end\nclass C < Base; include Comparable; end\n"
      expect(RubyRun.stdout("#{source}p C.instance_method(:between?).owner\n").chomp).to eq("Comparable")
      expect(owner_of(resolve(scope_for(source), :between?))).to eq(:unknown)
    end

    it "skips an external RBS knows and whose declaration lacks the name" do
      source = "class Base; def foo = 1; end\nclass C < Base; include Comparable; end\n"
      expect(owner_of(resolve(scope_for(source), :foo))).to eq("Base")
    end
  end

  # The external-entry precision follow-up (#1562): a declared project module with no `def`, and an RBS-unknown
  # gem module for `:override`.
  describe "external ancestors the project declares or RBS does not know" do
    def override_resolve(scope, name)
      resolution.resolve(scope, "C", name, :instance, question: :override) { |owner| scope.user_def_for(owner, name) }
    end

    let(:concern_shim) do
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

    # A module the project declares without a `def` is an external entry no table can vouch for: a macro in
    # `included do`, or a hook defined outside the body (`def Q.included(b) = ...`), defines on the includer with
    # nothing recorded. It declines, as does a gem module declared nowhere and absent from RBS (a future gem-source
    # approach, `dependencies.source_inference`, could read it).
    it "declines on a declared def-less module whose body holds nothing" do
      source = "class B; def foo = 1; end\nmodule Empty; end\nclass C < B; include Empty; end\n"
      expect(RubyRun.stdout("#{source}p C.instance_method(:foo).owner\n").chomp).to eq("B")
      expect(owner_of(resolve(project_scope("a.rb" => source), :foo))).to eq(:unknown)
    end

    it "declines on a concern whose included block calls a macro (custom_macro)" do
      source = <<~RUBY
        class Base; def self.my_macro(n) = define_method(n) { :m }; def foo = 1; end
        module Q
          extend ActiveSupport::Concern
          included do
            my_macro :foo
          end
        end
        class C < Base; include Q; end
      RUBY
      expect(RubyRun.stdout("#{source}p C.instance_method(:foo).owner\n", prelude: concern_shim).chomp).to eq("C")
      expect(owner_of(resolve(project_scope("a.rb" => source), :foo))).to eq(:unknown)
    end

    it "declines on a hook defined outside the module body" do
      source = <<~RUBY
        class Base; def foo = 1; end
        module Q; end
        def Q.included(b) = b.attr_reader(:foo)
        class C < Base; include Q; end
      RUBY
      expect(RubyRun.stdout("#{source}p C.instance_method(:foo).owner\n").chomp).to eq("C")
      expect(owner_of(resolve(project_scope("a.rb" => source), :foo))).to eq(:unknown)
    end

    it "declines on a module neither declared nor in RBS, for every question" do
      source = "class B; def foo = 1; end\nclass C < B; include Gem::Authorization; end\n"
      scope = project_scope("a.rb" => source)
      expect(owner_of(override_resolve(scope, :foo))).to eq(:unknown)
      expect(owner_of(resolve(scope, :foo, question: :visibility))).to eq(:unknown)
      expect(owner_of(resolve(scope, :foo))).to eq(:unknown)
    end

    it "declines for :override on an RBS-known external that declares the name" do
      source = "class Base; def between?(a, b) = false; end\nclass C < Base; include Comparable; end\n"
      expect(owner_of(override_resolve(project_scope("a.rb" => source), :between?))).to eq(:unknown)
    end
  end

  # #986: a compact-header rename collision leaves `Mixin` naming two project modules. Both `include`s run, so a
  # multi-file mark is discharged for a name when none of the candidates answers it.
  describe "an ambiguous mixin spelling" do
    # The collision's header nestings are what the runner's rename pass leaves; the seed alone does not build them.
    def ambiguous_scope(wrapped_extra)
      scope = project_scope(
        "a.rb" => "class Outer; end\nclass Base; end\nmodule Mixin; def plain = 1; end\n" \
                  "module Solo; def from_solo = 1; end\nclass Outer::Leaf < Base; include Mixin; include Solo; end\n",
        "b.rb" => "module Wrap\n  module Mixin\n    def wrapped = 1\n#{wrapped_extra}  end\n  " \
                  "class Outer::Leaf; include Mixin; end\nend\n"
      )
      nestings = { "Outer::Leaf" => { "Mixin" => [[], ["Wrap"]] } }
      scope.with_discovery(scope.discovery.with(discovered_header_nestings: nestings))
    end

    def arity_resolve(scope, name)
      answer = lambda do |chain, from|
        chain.entries.each_with_index do |entry, index|
          next if index < from || entry.external?

          node = scope.user_def_for(entry.name, name)
          return described_class::Hit.new(node, entry.name, index, entry.side) if node
        end
        nil
      end
      resolution.resolve(scope, "Outer::Leaf", name, :instance, question: :arity, &answer)
    end

    it "discharges the mark when no candidate answers the name" do
      scope = ambiguous_scope("")
      expect(Rigor::Scope::ResolutionChain.for(scope, "Outer::Leaf", :instance, :arity).entries.map(&:name))
        .to include("Mixin", "Wrap::Mixin")
      expect(owner_of(arity_resolve(scope, :from_solo))).to eq("Solo")
    end

    it "declines when one candidate defines the name" do
      expect(owner_of(arity_resolve(ambiguous_scope("    def from_solo = 2\n"), :from_solo))).to eq(:unknown)
    end
  end

  # ADR-119 WD3 (errata 2026-10-08, PR C2-a) — the singleton side: a hook's edge is recorded on no includer, so
  # the read declines where one could have landed ahead of its last candidate (`SingletonHookDecline`). Each fixture
  # shows Ruby's `singleton_class.ancestors` (up to `#<Class:Object>`) and the owner of the method read beside the read.
  describe "the singleton side" do
    let(:concern_shim) do
      <<~RUBY
        module ActiveSupport
          module Concern
            def self.extended(base) = base.instance_variable_set(:@_included_block, nil)

            def class_methods(&block)
              mod = const_defined?(:ClassMethods, false) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)
              mod.module_eval(&block)
            end

            def included(base = nil, &block)
              if base.nil?
                @_included_block = block
              else
                super
                base.extend(const_get(:ClassMethods)) if const_defined?(:ClassMethods, false)
                base.class_eval(&@_included_block) if @_included_block
              end
            end
          end
        end
      RUBY
    end

    # `[ancestors, owner, value]` of `receiver.name` under Ruby, the ancestors cut before `#<Class:Object>`.
    def ruby_singleton(source, receiver, name, prelude: nil)
      program = <<~RUBY
        #{source}
        ancestors = #{receiver}.singleton_class.ancestors.take_while { |mod| mod != Object.singleton_class }
        found = #{receiver}.respond_to?(:#{name}) ? #{receiver}.method(:#{name}) : nil
        value = found && found.arity.zero? ? found.call : nil
        puts [ancestors.map(&:to_s), found&.owner.to_s, value.inspect].inspect
      RUBY
      eval(RubyRun.stdout(program, prelude: prelude)) # rubocop:disable Security/Eval
    end

    def singleton(scope, klass, name) = owner_of(resolve(scope, name, side: :singleton, klass: klass))

    it "is Known for an own `def self.x` though a concern is included (a)" do
      source = <<~RUBY
        module X; def x = :hook; end
        module Concern
          extend ActiveSupport::Concern
          included do
            extend X
          end
        end
        class C; include Concern; def self.x = :own; end
      RUBY
      expect(ruby_singleton(source, "C", :x, prelude: concern_shim)).to eq([%w[#<Class:C> X], "#<Class:C>", ":own"])
      expect(singleton(scope_for(source), "C", :x)).to eq("C")
    end

    # #1592's hook shapes: the hook's `extend` is recorded on no includer, so the chain alone answers Absent.
    describe "a hook that extends its includer (#1592)" do
      {
        "a concern's `included do extend X end`" =>
          ["module Q\n  extend ActiveSupport::Concern\n  included do\n    extend X\n  end\nend", "X"],
        "a concern's `class_methods do`" =>
          ["module Q\n  extend ActiveSupport::Concern\n  class_methods do\n    def bar = :x\n  end\nend", "Q::ClassMethods"],
        "`self.included(base) = base.extend(X)`" =>
          ["module Q; def q = 1; def self.included(base) = base.extend(X); end", "X"],
        "a hook the walk cannot see, reached through `send(:extend, Hooks)` (only its `\"*\"`)" =>
          ["module Hooks; def included(base) = base.extend(X); end\n" \
           "module Q; def q = 1; send(:extend, Hooks); end", "X"]
      }.each do |label, (hook, owner)|
        it "declines #{label}" do
          source = "module X; def bar = :x; end\n#{hook}\nclass K; include Q; end\n"
          ancestors, ruby_owner, = ruby_singleton(source, "K", :bar, prelude: concern_shim)
          expect([ancestors.first(2), ruby_owner]).to eq([["#<Class:K>", owner], owner])
          expect(singleton(scope_for(source), "K", :bar)).to eq(:unknown)
        end
      end
    end

    # #1567's singleton shape: an extended module's own includes come after it, and an RBS-known module in the
    # class's own instance level that lacks the name is clean.
    it "is Known M#foo through an extended module's include (c)" do
      source = <<~RUBY
        module M; def foo = :m; end
        module A; include M; end
        class Base; def self.foo = :base; end
        class C < Base; include Comparable; extend A; end
      RUBY
      expect(ruby_singleton(source, "C", :foo)).to eq([%w[#<Class:C> A M #<Class:Base>], "M", ":m"])
      expect(singleton(scope_for(source), "C", :foo)).to eq("M")
    end

    # #1607: `C`'s `extend M` is skipped in Ruby (M is already reached through Base's singleton), so Base's own
    # `def self.foo` answers; had Base's `extend M` run after C's, M would. A fork, Unknown.
    it "is Unknown on #1607's fork (d)" do
      source = <<~RUBY
        module M; def foo(x) = x; end
        class Base; extend M; def self.foo = 1; end
        class C < Base; extend M; end
      RUBY
      expect(ruby_singleton(source, "C", :foo)).to eq([%w[#<Class:C> #<Class:Base> M], "#<Class:Base>", "1"])
      expect(singleton(scope_for(source), "C", :foo)).to eq(:unknown)
    end

    # A superclass's `inherited` defines on every subclass's singleton before the subclass's body runs, so it beats
    # the subclass's extends but not its own `def self.x`.
    describe "a superclass's inherited hook (e)" do
      let(:source) do
        <<~RUBY
          module X; def x = :x; end
          class Base
            def self.inherited(sub)
              super
              sub.define_singleton_method(:x) { :hook }
            end
          end
          class C < Base; extend X; end
          class D < Base; extend X; def self.x = :own; end
          class E < Base; end
        RUBY
      end

      it "declines a read the hook can reach" do
        expect(ruby_singleton(source, "C", :x)).to eq([%w[#<Class:C> X #<Class:Base>], "#<Class:C>", ":hook"])
        expect(ruby_singleton(source, "E", :x)).to eq([%w[#<Class:E> #<Class:Base>], "#<Class:E>", ":hook"])
        scope = scope_for(source)
        expect([singleton(scope, "C", :x), singleton(scope, "E", :x)]).to eq(%i[unknown unknown])
      end

      it "is Known for the subclass's own override" do
        expect(ruby_singleton(source, "D", :x)).to eq([%w[#<Class:D> X #<Class:Base>], "#<Class:D>", ":own"])
        expect(singleton(scope_for(source), "D", :x)).to eq("D")
      end
    end

    # The extends fold copies X#x onto C's singleton tables, so the read finds it at C's own entry. The copy is not
    # where Ruby finds it: the read asks past it, X answers at its own entry, and a hook in the same level can still
    # insert ahead of X.
    describe "a fold copy beside a hook-capable entry (f)" do
      let(:source) do
        <<~RUBY
          module X; def x = :x; end
          module Y; def x = :y; end
          module Concern
            extend ActiveSupport::Concern
            included do
              extend Y
            end
          end
          class C; extend X; include Concern; end
          class D; extend X; include Concern; def self.x = :own; end
        RUBY
      end

      it "declines the copy" do
        expect(ruby_singleton(source, "C", :x, prelude: concern_shim)).to eq([%w[#<Class:C> Y X], "Y", ":y"])
        expect(singleton(scope_for(source), "C", :x)).to eq(:unknown)
      end

      it "is Known for an own def" do
        expect(ruby_singleton(source, "D", :x, prelude: concern_shim)).to eq([%w[#<Class:D> Y X], "#<Class:D>", ":own"])
        expect(singleton(scope_for(source), "D", :x)).to eq("D")
      end
    end

    # A singleton `def` the class's own body did not write (`C.class_eval do def self.x end`, written before the
    # hook ran) is read one past the class entry, so its own level's hooks are tested.
    it "declines a def written outside the class body beside a hook-capable entry (f)" do
      source = <<~RUBY
        module Concern; def c = 1; def self.included(base) = base.define_singleton_method(:x) { :hook }; end
        class C; end
        C.class_eval do
          def self.x = :early
        end
        class C; include Concern; end
      RUBY
      expect(ruby_singleton(source, "C", :x)).to eq([%w[#<Class:C>], "#<Class:C>", ":hook"])
      expect(singleton(scope_for(source), "C", :x)).to eq(:unknown)
    end

    # An external superclass entry stands for its whole singleton tail and is asked for a singleton method.
    describe "an external superclass (g)" do
      it "declines a name the superclass's singleton declares" do
        source = "class K < Exception; end\n"
        expect(ruby_singleton(source, "K", :exception)[1]).to eq("#<Class:Exception>")
        expect(singleton(scope_for(source), "K", :exception)).to eq(:unknown)
      end

      it "is not Absent for a singleton-only name (`File.exist?`)" do
        source = "class C < File; end\n"
        expect(ruby_singleton(source, "C", :exist?)[1]).to eq("#<Class:File>")
        expect(singleton(scope_for(source), "C", :exist?)).to eq(:unknown)
      end

      it "is Absent for a name nothing defines" do
        source = "class C < File; end\n"
        expect(ruby_singleton(source, "C", :no_such_method_anywhere)[1]).to eq("")
        expect(singleton(scope_for(source), "C", :no_such_method_anywhere)).to eq(:absent)
      end
    end

    describe "an extended RBS-known module (h)" do
      let(:source) do
        <<~RUBY
          module X; def foo = :x; def between?(a, b) = :x; end
          class C; extend X; extend Comparable; end
        RUBY
      end

      it "is passed where its declaration lacks the name" do
        expect(ruby_singleton(source, "C", :foo)).to eq([%w[#<Class:C> Comparable X], "X", ":x"])
        expect(singleton(scope_for(source), "C", :foo)).to eq("X")
      end

      # The fold copied X#between? onto C, which would read ahead of Comparable: the copy is asked past.
      it "declines where its declaration has the name" do
        expect(ruby_singleton(source, "C", :between?)[1]).to eq("Comparable")
        expect(singleton(scope_for(source), "C", :between?)).to eq(:unknown)
      end
    end

    # A module whose methods come from a `define_method` loop holds no recorded method, so the chain carries it as an
    # external entry; it is declared, so its hook test is the project one, and its own answer is unknown.
    describe "an extended declared module whose methods come from a define_method loop (i)" do
      let(:source) do
        <<~RUBY
          module U; [:foo].each { |name| define_method(name) { :u } }; end
          module X; def bar = :x; end
          class C; extend U; end
          class D; extend U; extend X; end
        RUBY
      end

      it "declines the name it may define" do
        expect(ruby_singleton(source, "C", :foo)).to eq([%w[#<Class:C> U], "U", ":u"])
        expect(singleton(scope_for(source), "C", :foo)).to eq(:unknown)
      end

      it "is no hook signal for a definer ahead of it" do
        expect(ruby_singleton(source, "D", :bar)).to eq([%w[#<Class:D> X U], "X", ":x"])
        expect(singleton(scope_for(source), "D", :bar)).to eq("X")
      end
    end

    # `include Hk` written in `Outer::C` names `Outer::Hk` or `::Hk` by load order; neither declares a method, so the
    # chain holds the spelling as external. Every declared candidate is tested and the concern among them declines.
    it "declines when any declared candidate of an ambiguous spelling is hook-capable (j)" do
      hooks = <<~RUBY
        module Y; def bar = :y; end
        module Hk
          extend ActiveSupport::Concern
          included do
            extend Y
          end
        end
      RUBY
      host = "module X; def bar = :x; end\nmodule Outer\n  class C; extend X; include Hk; end\nend\n"
      quiet = "module Outer; module Hk; NAME = 1; end; end\n"
      expect(ruby_singleton("#{hooks}#{quiet}#{host}", "Outer::C", :bar, prelude: concern_shim)[1]).to eq("X")
      expect(ruby_singleton("#{hooks}#{host}#{quiet}", "Outer::C", :bar, prelude: concern_shim)[1]).to eq("Y")
      expect(singleton(scope_for("#{hooks}#{quiet}#{host}"), "Outer::C", :bar)).to eq(:unknown)
    end

    # The rule's known remainders, pinned at today's answer: FLIP each when its fix lands.
    describe "remainders" do
      # The extends table records `class << self; prepend P` as an `extend`, so the chain places P after the
      # singleton and trusts C's own def; Ruby calls P#foo.
      it "pins `class << self; prepend P` read past an own def (wrong: Ruby calls P)" do
        source = "module P; def foo = :p; end\nclass C; class << self; prepend P; end; def self.foo = :own; end\n"
        expect(ruby_singleton(source, "C", :foo)).to eq([%w[P #<Class:C>], "P", ":p"])
        expect(singleton(scope_for(source), "C", :foo)).to eq("C")
      end

      it "pins a concern as capable for every name (Unknown where Ruby calls X)" do
        source = <<~RUBY
          module X; def bar = :x; end
          module Concern
            extend ActiveSupport::Concern
            included do
              attr_reader :unrelated
            end
          end
          class C; include Concern; extend X; end
        RUBY
        expect(ruby_singleton(source, "C", :bar, prelude: concern_shim)).to eq([%w[#<Class:C> X], "X", ":x"])
        expect(singleton(scope_for(source), "C", :bar)).to eq(:unknown)
      end

      it "pins an own def trusted against its own level's U2 hook (wrong: Ruby calls the hook's)" do
        source = <<~RUBY
          module Concern
            extend ActiveSupport::Concern
            included do
              def self.x = :hook
            end
          end
          class C; def self.x = :own; include Concern; end
        RUBY
        expect(ruby_singleton(source, "C", :x, prelude: concern_shim)).to eq([%w[#<Class:C>], "#<Class:C>", ":hook"])
        expect(singleton(scope_for(source), "C", :x)).to eq("C")
      end

      it "pins a superclass that only extends: two forks, so even an own def declines" do
        source = "module Z; def z = 1; end\nmodule Y; include Z; end\nclass Base; extend Y; end\n" \
                 "class C < Base; def self.own = :own; end\n"
        expect(ruby_singleton(source, "C", :own)).to eq([%w[#<Class:C> #<Class:Base> Y Z], "#<Class:C>", ":own"])
        expect(singleton(scope_for(source), "C", :own)).to eq(:unknown)
      end
    end
  end

  describe "the answer function's contract" do
    it "raises for a hit that is behind the position it was asked from" do
      scope = scope_for("class Base; def foo = 1; end\nclass C < Base; end\n")
      backwards = proc { |_chain, _position| described_class::Hit.new(1, "C", 0, :instance) }
      expect { resolution.resolve(scope, "C", :foo, :instance, question: :arity, from: 1, &backwards) }
        .to raise_error(ArgumentError, /backwards/)
    end

    it "keeps its helpers private" do
      reachable = %i[collapse candidates possible? outcomes].map { |name| described_class.respond_to?(name) }
      expect(reachable).to all(be(false))
    end
  end
end
