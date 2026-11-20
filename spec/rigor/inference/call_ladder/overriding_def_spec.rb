# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "fileutils"

# ADR-116 C4 — `CallLadder::OverridingDef` is the `overriding_def` rung of the call ladder: a call on an instance whose
# class has its own source `def`, no declaration of its own, and a declaration a project-declared ancestor wrote,
# answered from the own `def`'s body (ADR-110 WD1, #856). The examples write a project signature, index a snippet
# over it, build the site the typer would, and ask the module with a real typer over the snippet's scope. The module
# reads `typer.scope` and asks `CallLadder::UserMethod.infer` for the body, so what a body types as is that rung's;
# whether the answer reaches a check run is `overriding_def_over_inherited_declaration_spec.rb`'s.
RSpec.describe Rigor::Inference::CallLadder::OverridingDef do
  around do |example|
    Dir.mktmpdir("rigor-overriding-def-rung-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:combinator) { Rigor::Type::Combinator }
  let(:environment) do
    FileUtils.mkdir_p("sig")
    File.write("sig/base.rbs", <<~RBS)
      class Base
        def label: () -> nil
        def twice: (Integer) -> nil
        def []: (Symbol) -> nil
        def each: () { () -> untyped } -> nil
        def plain: () -> nil
      end
      class Child < Base
      end
      class Own < Base
        def label: () -> Integer
      end
    RBS
    Rigor::Environment.for_project(signature_paths: ["sig"])
  end
  let(:program) do
    Prism.parse(<<~RUBY).value
      class Base
        def label = nil
      end
      class Child < Base
        def label = "child"
        def twice(n) = n
        def [](key) = 0
        def each = yield
        def to_s = "child"
      end
      class Own < Base
        def label = "own"
      end
      c = Child.new
      c[:a] += 1
      c.label
      c.twice(3)
      c.each { :seen }
      c.to_s
      c.plain
    RUBY
  end
  let(:statements) { program.statements.body }
  let(:index_write) { statements[4] }
  let(:scope) do
    Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))
                                  .fetch(statements.last)
  end
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }
  let(:child) { scope.local(:c) }

  def site(method_name, call_node, args: [], receiver: child, block_type: nil)
    cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type,
       environment: scope.environment, call_node: call_node, scope: scope)
  end

  def answer(...) = described_class.try_call(site(...), typer)

  describe ".try_call" do
    it "types the call from the receiver's own def, not from the declaration an ancestor wrote" do
      expect(child.describe).to eq("Child")
      expect(answer(:label, statements[5]).describe).to eq('"child"')
      expect(answer(:twice, statements[6], args: [combinator.constant_of(3)]).describe).to eq("3")
    end

    # The read of `c[:a] += 1` has no call node of its own: the write node stands in, and it has no `name`.
    it "takes the method name from the site, not from the call node" do
      expect(index_write).to be_a(Prism::IndexOperatorWriteNode)
      expect(index_write).not_to respond_to(:name)
      expect(answer(:[], index_write, args: [combinator.constant_of(:a)]).describe).to eq("0")
      expect(answer(:label, statements[6]).describe).to eq('"child"')
    end

    # The rung re-types the own `def` with no block type, as it did in the typer: `c.each { :seen }` is not `:seen`
    # here, where the user-method rung, which is handed the site's block type, answers `:seen`.
    it "types the body with no block type, whatever the site's" do
      seen = combinator.constant_of(:seen)
      yielding = site(:each, statements[7], block_type: seen)

      expect(Rigor::Inference::CallLadder::UserMethod.try_call(yielding, typer)).to eq(seen)
      expect(described_class.try_call(yielding, typer)).to eq(combinator.untyped)
    end

    # The own `def` shadows the inherited declaration, so a body it cannot re-type is `Dynamic[top]`, never that
    # declaration's `nil`: `twice` asked with no argument binds no `n`.
    it "answers `Dynamic[top]` for an own def whose body it cannot re-type" do
      expect(Rigor::Inference::CallLadder::UserMethod.infer(child, statements[6], [], :twice, nil, typer)).to be_nil
      expect(answer(:twice, statements[6])).to eq(combinator.untyped)
    end

    it "answers nothing where the gate does not hold" do
      expect(answer(:plain, statements[9])).to be_nil
      expect(answer(:label, statements[5], receiver: combinator.nominal_of("Own"))).to be_nil
      expect(answer(:to_s, statements[8])).to be_nil
      expect(answer(:label, statements[5], receiver: combinator.singleton_of("Child"))).to be_nil
    end
  end

  describe ".overriding_own_def?" do
    # Each condition fails on its own: no own `def` (`plain`), a declaration of the class's own (`Own#label`), and a
    # declaration only a bundled ancestor wrote (`Object#to_s`). A class object is no instance.
    it "holds for an own def that inherits a project-declared ancestor's declaration, and for nothing else" do
      expect(described_class.overriding_own_def?(child, :label, typer)).to be(true)
      expect(described_class.overriding_own_def?(child, :[], typer)).to be(true)
      expect(described_class.overriding_own_def?(child, :plain, typer)).to be(false)
      expect(described_class.overriding_own_def?(combinator.nominal_of("Own"), :label, typer)).to be(false)
      expect(described_class.overriding_own_def?(child, :to_s, typer)).to be(false)
      expect(described_class.overriding_own_def?(combinator.singleton_of("Child"), :label, typer)).to be(false)
    end

    it "takes the receiver, the method name and the typer" do
      expect(described_class.method(:overriding_own_def?).parameters).to eq([%i[req receiver], %i[req method_name],
                                                                             %i[req typer]])
    end
  end

  it "exposes the rung and its gate, and hides the rest" do
    expect(described_class.singleton_class.public_instance_methods(false))
      .to contain_exactly(:try_call, :overriding_own_def?)
    expect { described_class.project_declared_owner?(nil, scope) }.to raise_error(NoMethodError, /private/)
  end
end
