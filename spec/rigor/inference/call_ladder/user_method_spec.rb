# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `CallLadder::UserMethod` is the `user_method` rung of the call ladder: a call on an instance of a
# project class, answered from the body of the `def` Ruby calls. The examples index a snippet, build the site the
# typer would, and ask the module with a real typer over the snippet's scope; the module reads `typer.scope` and
# calls back `class_graph_buckets`, `positional_correspondence`, `infer_user_method_return` and
# `degrade_if_overridable`. What a body types as is `infer_user_method_return`'s, and its specs are the typer's.
RSpec.describe Rigor::Inference::CallLadder::UserMethod do
  let(:combinator) { Rigor::Type::Combinator }
  let(:program) do
    Prism.parse(<<~RUBY).value
      class Box
        def [](key) = 0
        def label = "box"
        def twice(n) = n
        def each = yield
        def stop = raise("stopped")
      end
      Point = Struct.new(:x) do
        def shifted = x
      end
      b = Box.new
      b[:a] += 1
      b.label
      b.twice(3)
      b.each { :seen }
    RUBY
  end
  let(:statements) { program.statements.body }
  let(:index_write) { statements[3] }
  let(:scope) { Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)[index_write] }
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }
  let(:box) { scope.local(:b) }

  def site(method_name, call_node, args: [], receiver: box, block_type: nil)
    cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type,
       environment: scope.environment, call_node: call_node, scope: scope)
  end

  describe ".try_call" do
    it "types the call from the body of the receiver's own def" do
      expect(described_class.try_call(site(:label, statements[4]), typer).describe).to eq('"box"')
      expect(described_class.try_call(site(:twice, statements[5], args: [combinator.constant_of(3)]), typer).describe)
        .to eq("3")
    end

    # The read of `b[:a] += 1` has no call node of its own: the write node stands in, and it has no `name`.
    it "takes the method name from the site, not from the call node" do
      expect(index_write).to be_a(Prism::IndexOperatorWriteNode)
      expect(index_write).not_to respond_to(:name)
      expect(described_class.try_call(site(:[], index_write, args: [combinator.constant_of(:a)]), typer).describe)
        .to eq("0")
      expect(described_class.try_call(site(:label, statements[5]), typer).describe).to eq('"box"')
    end

    it "takes the block type from the site" do
      seen = combinator.constant_of(:seen)

      expect(described_class.try_call(site(:each, statements[6], block_type: seen), typer)).to eq(seen)
      expect(described_class.try_call(site(:each, statements[6]), typer).describe).not_to eq(":seen")
    end

    it "answers nothing for a receiver the gate does not admit, and for a name with no def" do
      expect(described_class.try_call(site(:label, statements[4], receiver: combinator.singleton_of("Box")), typer))
        .to be_nil
      expect(described_class.try_call(site(:label, statements[4], receiver: combinator.nominal_of("String")), typer))
        .to be_nil
      expect(described_class.try_call(site(:missing, statements[4]), typer)).to be_nil
    end

    it "answers `bot` for a body that always raises" do
      expect(described_class.try_call(site(:stop, statements[4]), typer)).to be_a(Rigor::Type::Bot)
    end
  end

  describe ".infer" do
    it "is the rung with its arguments as positionals: the answer of `try_call` for the same call" do
      three = [combinator.constant_of(3)]
      asked = described_class.infer(box, statements[5], three, :twice, nil, typer)

      expect(asked.describe).to eq("3")
      expect(asked).to eq(described_class.try_call(site(:twice, statements[5], args: three), typer))
      expect(described_class.infer(box, statements[4], [], :missing, nil, typer)).to be_nil
    end

    # Indexing the snippet typed its four calls, so the names it did not call are the ones to watch.
    it "keeps what it resolved in the typer's class-graph memo, under its own bucket" do
      resolved = -> { typer.class_graph_buckets.fetch(:typing_def).fetch("Box").keys }

      expect(resolved.call).to include(:label)
      expect(resolved.call).not_to include(:stop)
      described_class.infer(box, statements[4], [], :stop, nil, typer)
      expect(resolved.call).to include(:stop)
    end
  end

  describe ".user_inference_receiver?" do
    it "admits an instance of a class, and a struct or data instance that has a class name" do
      point = scope.type_of(Prism.parse("Point.new(1)").value.statements.body.first)

      expect(described_class.user_inference_receiver?(box)).to be(true)
      expect(point).to be_a(Rigor::Type::StructInstance)
      expect(described_class.user_inference_receiver?(point)).to be(true)
    end

    it "admits no class object, value, union or missing receiver" do
      others = [combinator.singleton_of("Box"), combinator.constant_of(1), combinator.untyped,
                combinator.union(box, combinator.constant_of(nil)), nil]

      expect(others.map { |receiver| described_class.user_inference_receiver?(receiver) }).to all(be(false))
    end

    it "takes the receiver alone" do
      expect(described_class.method(:user_inference_receiver?).arity).to eq(1)
    end
  end

  it "exposes the rung, its positional entry and its gate, and hides the rest" do
    expect(described_class.singleton_class.public_instance_methods(false))
      .to contain_exactly(:try_call, :infer, :user_inference_receiver?)
    expect { described_class.every_project_definer("Box", :label, scope) }.to raise_error(NoMethodError, /private/)
  end
end
