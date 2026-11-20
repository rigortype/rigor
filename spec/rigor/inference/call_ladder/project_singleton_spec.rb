# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `CallLadder::ProjectSingleton` is the `project_singleton` rung of the call ladder: a call on a class
# object, answered from the `def self.` Ruby calls, or on a constant that holds an ordinary object, answered from its
# `class << CONST` body. The examples index a snippet, build the site the typer would, and ask the module with a real
# typer over the snippet's scope; the module reads `typer.scope` and calls back `class_graph_buckets`,
# `positional_correspondence`, `infer_user_method_return` and `degrade_if_overridable`. What a body types as is
# `infer_user_method_return`'s, and which definer a class-side read withholds is the integration specs' (the
# singleton ancestor walk, its prepends, its hooks).
RSpec.describe Rigor::Inference::CallLadder::ProjectSingleton do
  let(:combinator) { Rigor::Type::Combinator }
  let(:program) do
    Prism.parse(<<~RUBY).value
      class Reg
        def self.[](key) = 0
        def self.label = "reg"
        def self.twice(n) = n
        def self.each = yield
      end
      class Sub < Reg
      end
      class Base
        def self.kind = "base"
      end
      class Kid < Base
        def self.kind = "kid"
      end
      OBJ = Object.new
      class << OBJ
        def greet = "hi"
      end
      Reg[:a] += 1
      Reg.label
      Reg.twice(3)
      Reg.each { :seen }
      OBJ.greet
      Base.kind
      Reg.new.label
    RUBY
  end
  let(:statements) { program.statements.body }
  let(:index_write) { statements[6] }
  let(:scope) { Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)[index_write] }
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }
  let(:reg) { combinator.singleton_of("Reg") }

  def site(method_name, call_node, args: [], receiver: reg, block_type: nil)
    cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type,
       environment: scope.environment, call_node: call_node, scope: scope)
  end

  def answer(...) = described_class.try_call(site(...), typer)

  describe ".try_call" do
    it "types a call on a class object from the body of its own `def self.`, and of its superclass's" do
      expect(answer(:label, statements[7]).describe).to eq('"reg"')
      expect(answer(:twice, statements[8], args: [combinator.constant_of(3)]).describe).to eq("3")
      expect(answer(:label, statements[7], receiver: combinator.singleton_of("Sub")).describe).to eq('"reg"')
    end

    # The read of `Reg[:a] += 1` has no call node of its own: the write node stands in, and it has no `name`.
    it "takes the method name from the site, not from the call node" do
      expect(index_write).to be_a(Prism::IndexOperatorWriteNode)
      expect(index_write).not_to respond_to(:name)
      expect(answer(:[], index_write, args: [combinator.constant_of(:a)]).describe).to eq("0")
      expect(answer(:label, statements[8]).describe).to eq('"reg"')
    end

    it "takes the block type from the site" do
      seen = combinator.constant_of(:seen)

      expect(answer(:each, statements[9], block_type: seen)).to eq(seen)
      expect(answer(:each, statements[9]).describe).not_to eq(":seen")
    end

    it "types a call on a constant that holds an ordinary object from its `class << CONST` body" do
      object = scope.type_of(statements[10].receiver)

      expect(object).to be_a(Rigor::Type::Nominal)
      expect(answer(:greet, statements[10], receiver: object).describe).to eq('"hi"')
    end

    # ADR-57 — `Base.kind`'s literal is not adopted where a subclass redefines it: the class-side twin of the
    # instance side's overridable gate, keyed on the owner.
    it "does not adopt the literal of a `def self.` a subclass redefines" do
      expect(answer(:kind, statements[11], receiver: combinator.singleton_of("Base")))
        .to eq(combinator.untyped)
      expect(answer(:kind, statements[11], receiver: combinator.singleton_of("Kid")).describe).to eq('"kid"')
    end

    # An instance answers from a `class << CONST` body only where the call names the constant (`OBJ.greet`).
    it "answers nothing for an instance, for a name with no def, and for a missing receiver" do
      expect(answer(:label, statements[12], receiver: combinator.nominal_of("Reg"))).to be_nil
      expect(answer(:missing, statements[7])).to be_nil
      expect(answer(:label, statements[7], receiver: nil)).to be_nil
    end

    # Indexing the snippet typed its calls, so the names it did not call are the ones to watch.
    it "keeps what it resolved in the typer's class-graph memo, under its own bucket" do
      resolved = -> { typer.class_graph_buckets.fetch(:singleton_def).values.flat_map(&:values).flat_map(&:keys) }

      expect(resolved.call).not_to include(:missing)
      answer(:missing, statements[7])
      expect(resolved.call).to include(:missing)
    end
  end

  it "exposes the rung alone, and hides the rest" do
    expect(described_class.singleton_class.public_instance_methods(false)).to contain_exactly(:try_call)
    expect { described_class.singleton_copy_head("Reg", statements[0], scope) }
      .to raise_error(NoMethodError, /private/)
  end
end
