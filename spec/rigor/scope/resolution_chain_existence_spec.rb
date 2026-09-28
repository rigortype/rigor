# frozen_string_literal: true

require "spec_helper"

# ADR-24 (amended for #1570) — where the two worlds of `Scope::ResolutionChain` put different definers first,
# the def readers answer what the walk the chain replaced answered, and they keep returning a definer or nil —
# no third outcome. Many callers only test whether a reader returned something (the `call.*` suppressions,
# `ExpressionTyper`'s implicit-self probes, `ProjectMethodOwnership`, `ErrorInfo`, the struct `.with` guard,
# a plugin's `project_defines?`); a disagreement read as absence there would stop suppressing a diagnostic on
# correct code. Each example asks one such caller about a name whose first definer the two worlds dispute.
RSpec.describe "existence probes over a contested resolution chain" do
  let(:source) do
    <<~RUBY
      module M
        def foo(x) = x
        def with = self
      end

      class Base
        include M

        def foo = 1
        def with = :base
      end

      class C < Base
        include M
      end

      class Plain < Base
      end

      class SBase
        include M

        def self.build = :sbase
        def self.===(other) = true
      end

      class S < SBase
        include M
      end
    RUBY
  end

  let(:scope) do
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  def chain_of(name) = Rigor::Scope::ResolutionChain.for(scope, name, :instance, :methods)

  # The fixture must really be contested — and a class without the redundant include must not be — or every
  # example below would pass without exercising a disagreement.
  it "contests C's chain, where the two worlds put different definers of foo first, and not Plain's" do
    expect(chain_of("C")).to be_contested
    expect(chain_of("Plain")).not_to be_contested
    skip_world = chain_of("C").entries.map(&:name)
    retro_world = chain_of("C").retro.entries.map(&:name)
    expect([skip_world, retro_world]).to eq([%w[C Base M], %w[C M Base M]])
  end

  # The reader keeps master's answer there: its breadth-first walk reached `C`'s own `include M` before `Base`.
  it "answers master's definer, never nil, from Scope#user_def_through_ancestors" do
    node, owner = scope.user_def_through_ancestors("C", :foo)
    expect([owner, node&.location&.start_line]).to eq(["M", 2])
    expect(scope.discovered_method_through_ancestors?("C", :foo, :instance)).to be(true)
  end

  it "keeps the singleton-side probes answering defined" do
    expect(scope.singleton_def_through_ancestors("S", :build).first).not_to be_nil
    expect(scope.discovered_method_through_ancestors?("S", :build, :singleton)).to be(true)
  end

  it "keeps CheckRules' undefined-method suppression answering defined" do
    rules = Rigor::Analysis::CheckRules
    expect(rules.send(:project_defines_method?, scope, "C", :foo, :instance)).to be(true)
    expect(rules.send(:ancestry_declares_method?, scope, "C", :foo, :instance)).to be(true)
  end

  it "keeps ExpressionTyper's implicit-self and self-call probes answering defined" do
    typer = Rigor::Inference::ExpressionTyper.new(scope: scope)
    expect(typer.send(:instance_self_answers?, "C", :foo)).to be(true)
    expect(typer.send(:self_call_method_known?, "C", :foo)).to be(true)
    expect(typer.send(:singleton_self_answers?, "S", :build)).to be(true)
  end

  # `ProjectMethodOwnership.defines?` is what `ClosureEscapeAnalyzer` (a project `each` keeps the block's
  # narrowings only when nothing in the project defines it) and `GuardRebinding` ask; "not defined" there keeps
  # a narrowing the program may invalidate.
  it "keeps ProjectMethodOwnership and the RBS arms' shadow guard answering defined" do
    ownership = Rigor::Inference::ProjectMethodOwnership
    expect(ownership.send(:source_defines?, "C", :foo, :instance, scope)).to be(true)
    expect(ownership.send(:source_defines?, "S", :build, :singleton, scope)).to be(true)
    expect(ownership.defines?("C", :foo, :instance, scope)).to be(true)
    expect(ownership.defines?("C", :with, :instance, scope)).to be(true)
    rbs_dispatch = Rigor::Inference::MethodDispatcher::RbsDispatch
    expect(rbs_dispatch.send(:source_declares_through_ancestors?, scope, "C", :foo)).to be(true)
  end

  it "keeps ErrorInfo's singleton `===` probe answering defined" do
    expect(Rigor::Inference::ErrorInfo.send(:own_case_equality?, "S", scope)).to be(true)
  end

  it "keeps the struct `.with` guard seeing a hand-written `with`" do
    receiver = Rigor::Type::StructInstance.new({ a: Rigor::Type::Combinator.untyped }, "C")
    materialization = Rigor::Inference::MethodDispatcher::StructMaterialization
    expect(materialization.send(:hand_written_with?, receiver, scope)).to be(true)
  end

  it "keeps the active_model_serializers plugin's project-definition probe answering defined" do
    require File.expand_path("../../../plugins/rigor-active-model-serializers/lib/rigor-active-model-serializers",
                             __dir__)
    plugin = Rigor::Plugin::ActiveModelSerializers.allocate
    expect(plugin.send(:project_defines?, "C", :foo, scope)).to be(true)
    expect(plugin.send(:project_defines_object?, "C", scope)).to be(false)
  end
end
