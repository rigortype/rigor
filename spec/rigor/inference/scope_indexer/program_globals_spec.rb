# frozen_string_literal: true

require "spec_helper"
require "delegate"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (L4) — `ScopeIndexer::ProgramGlobals` is the program-global pre-pass of `ScopeIndexer.index`. The
# examples hand `seed_program_globals` a parsed snippet and a scope and read the answer off the scope it returns:
# no index is built and no body is evaluated, so the pre-pass alone decides each table. `scope_indexer_spec.rb` pins
# the same seed through `ScopeIndexer.index`, where a method body reads it back.
RSpec.describe Rigor::Inference::ScopeIndexer::ProgramGlobals do
  let(:combinator) { Rigor::Type::Combinator }
  let(:scope) { Rigor::Scope.empty }

  def seed(source, start = scope) = described_class.seed_program_globals(Prism.parse(source).value, start)

  def described(table) = table.transform_values(&:describe)

  # The default environment, except that it declares each global of `declared` as given. It records the `builtin:`
  # it was asked with.
  def environment_declaring(declared)
    Class.new(SimpleDelegator) do
      attr_reader :asked

      define_method(:global_for_name) do |name, builtin: false|
        (@asked ||= []) << builtin
        declared.fetch(name) { __getobj__.global_for_name(name, builtin: builtin) }
      end
    end.new(Rigor::Environment.default)
  end

  describe "the written globals" do
    it "records each global the file writes, at the top level and in any body, as the union of its writes" do
      seeded = seed(<<~RUBY)
        $a = 1
        $a = "s"
        def m = ($b = :in_def)
        class K; $c = 2.5; end
      RUBY

      expect(described(seeded.program_globals)).to eq({ "$a": '"s" | 1', "$b": ":in_def", "$c": "2.5" })
      expect(seeded.program_globals).to be_frozen
    end

    it "drops the emptiness of an empty seed literal" do
      expect(described(seed("$list = []\n$mode = %w[a]\n").program_globals))
        .to eq({ "$list": "Array[Dynamic[top]]", "$mode": '["a"]' })
    end

    it "binds each written global in the scope it answers, and leaves the scope it was handed as it was" do
      seeded = seed("$a = 1\n")

      expect(seeded.global(:$a)).to eq(combinator.constant_of(1))
      expect(seeded.declaration_sourced?(:global, :$a)).to be(false)
      expect(scope.global(:$a)).to be_nil
      expect(scope.program_globals).to be_empty
    end

    # Issues #1359 and #1360 — `$_` and `$~` are the frame's, `$!` and `$@` the rescue clause's and `$?` the
    # thread's: none holds a program-wide value.
    it "keeps `$_`, `$~`, `$!`, `$@` and `$?` out of the table and unbound" do
      seeded = seed("$_ = 'x'; $~ = nil; $! = nil; $@ = []; $? = nil; $kept = 1\n")

      expect(seeded.program_globals.keys).to eq([:$kept])
      expect(%i[$_ $~ $! $@ $?].map { |name| seeded.global(name) }).to all(be_nil)
    end
  end

  describe "the seed of a global Ruby's own signatures declare" do
    it "joins the non-nil declared members with the writes, binds it under the mark and keeps the writes apart" do
      seeded = seed("$VERBOSE = true\n$stdout = nil\n$plain = 1\n")
      discovery = seeded.discovery

      expect(described(discovery.program_globals)).to eq({ "$VERBOSE": "true", "$stdout": "nil", "$plain": "1" })
      expect(described(discovery.program_global_seeds)).to eq({ "$VERBOSE": "bool", "$stdout": "IO?" })
      expect(discovery.program_global_seeds).to be_frozen
      expect(%i[$VERBOSE $stdout $plain].map { |name| seeded.global(name).describe }).to eq(%w[bool IO? 1])
      expect(%i[$VERBOSE $stdout $plain].map { |name| seeded.declaration_sourced?(:global, name) })
        .to eq([true, true, false])
    end

    # Issue #1437 — the nil-bearing separators stay out of the join.
    it "leaves each separator with the union of its writes" do
      separators = %i[$/ $, $; $\\ $-0 $-F $-i]
      seeded = seed(separators.map { |name| "#{name} = ','\n" }.join)

      expect(seeded.program_globals.keys).to eq(separators)
      expect(seeded.discovery.program_global_seeds).to be_empty
      expect(separators.map { |name| seeded.global(name) }).to all(eq(combinator.constant_of(",")))
    end

    it "joins nothing for a declaration with no member but nil, spelled as the constant or as NilClass" do
      nil_class = combinator.nominal_of("NilClass")
      environment = environment_declaring(
        "$only_nil": combinator.constant_of(nil), "$nil_class": nil_class,
        "$all_nil": combinator.union(combinator.constant_of(nil), nil_class),
        "$nilable": combinator.union(nil_class, combinator.nominal_of("String"))
      )
      seeded = seed("$only_nil = 1\n$nil_class = 2\n$all_nil = 3\n$nilable = 4\n",
                    Rigor::Scope.empty(environment: environment))

      expect(described(seeded.discovery.program_global_seeds)).to eq({ "$nilable": "4 | String" })
      expect(seeded.global(:$only_nil)).to eq(combinator.constant_of(1))
    end

    it "asks the environment for the declaration Ruby's own signatures hold, once per written global" do
      environment = environment_declaring({})
      seed("$stdout = 1\n$plain = 2\n", Rigor::Scope.empty(environment: environment))

      expect(environment.asked).to eq([true, true])
    end
  end

  describe "the censuses the same walk fills" do
    it "starts each one empty" do
      discovery = seed("x = 1\n").discovery

      expect(discovery.patched_line_readers).to eq(Set[]).and be_frozen
      expect([discovery.clears_last_status, discovery.defines_case_equality]).to eq([false, false])
      expect(discovery.discovered_global_write_census).to be_empty
    end

    it "collects the `gets` and `readline` names the file patches in, wherever the call sits" do
      discovery = seed("define_method(:gets) { 1 }\nclass K; def m = Object.define_method(:readline) { 2 }; end\n")
                  .discovery

      expect(discovery.patched_line_readers).to eq(Set[:gets, :readline]).and be_frozen
    end

    it "records a call that may set `$?` to nil, and a `define_method` naming `===`" do
      expect(seed("def m = Process.waitall\n").discovery.clears_last_status).to be(true)
      expect(seed("def m = define_method(:===) { |o| true }\n").discovery.defines_case_equality).to be(true)
    end

    it "carries the file's implicit-self evidence and its in-effect refinements" do
      discovery = seed("x = 1\n").discovery

      expect(scope.discovery.implicit_self_evidence).to be_nil
      expect(discovery.implicit_self_evidence).to be_a(Rigor::Inference::LastLine::SelfEvidence)
      expect(discovery.in_effect_refinements).to be_a(Rigor::Inference::InEffectRefinements)
    end
  end

  describe "the global write census" do
    def with_census(entries)
      scope.with_discovery(scope.discovery.with(discovered_global_write_census: entries))
    end

    it "records the writers and aliases the file holds, and a mixin as the main object's only at the top level" do
      census = seed(<<~RUBY).discovered_global_write_census
        include Top
        class K; include InClass; end
        module M; extend InModule; end
        def m = ($b = 1)
        alias $new $old
      RUBY

      expect(census).to eq(Set[[:main_mixin, "Top"], %i[global_writer $b m], %i[alias $new], %i[alias $old]])
      expect(census).to be_frozen
    end

    it "answers the project's census itself when the file adds nothing to it" do
      project = Set[%i[alias $x].freeze].freeze

      expect(seed("x = 1\n", with_census(project)).discovered_global_write_census).to equal(project)
      expect(seed("alias $x $x\n", with_census(project)).discovered_global_write_census).to equal(project)
    end

    it "answers the frozen union of the project's census and the file's otherwise" do
      project = Set[%i[alias $x].freeze].freeze
      census = seed("alias $y $y\n", with_census(project)).discovered_global_write_census

      expect(census).to eq(Set[%i[alias $x], %i[alias $y]]).and be_frozen
      expect(project).to eq(Set[%i[alias $x]])
    end
  end

  it "exposes the seed alone, and keeps its name lists to itself" do
    expect(described_class.singleton_methods(false)).to eq([:seed_program_globals])
    expect(described_class.constants).to be_empty
  end
end
