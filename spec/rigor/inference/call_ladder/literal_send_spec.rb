# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `CallLadder::LiteralSend` is the `literal_send` rung of the call ladder: `recv.send(:name, …)` with a
# literal name, typed as `recv.name(…)`. Its target is a site of its own, asked of the dispatcher, the user-method rung
# and the project-singleton rung in that order (the `send_target` entry), and a receiver with a `send` of its own is
# answered ahead of them from that body. The examples index a snippet, build the call's site as the typer would, and
# ask the module with a real typer over the snippet's scope. The order of the target's rungs is the order pin's
# (`spec/rigor/inference/call_ladder_spec.rb`); what each rung answers is its own spec's.
RSpec.describe Rigor::Inference::CallLadder::LiteralSend do
  let(:combinator) { Rigor::Type::Combinator }
  let(:program) do
    Prism.parse(<<~RUBY).value
      class Box
        def label = "box"
        def twice(n) = n
      end
      class Wire
        def send(message) = :sent
        def label = :wired
      end
      class Reg
        def self.label = "reg"
      end
      b = Box.new
      w = Wire.new
      b.send(:label)
      b.send(:twice, 3)
      Reg.send(:label)
      "a".send(:upcase)
      w.send(:label)
      w.public_send(:label)
      b.send(name)
      b.send(:label) { 1 }
      b.send(:twice, *[3])
      b.label
    RUBY
  end
  let(:statements) { program.statements.body }
  let(:scope) { Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)[statements.last] }
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }

  # The call's own site, as `ExpressionTyper#call_result_type_for` builds it: its receiver, name and argument types.
  def site(index, receiver: nil)
    node = statements.fetch(index)
    receiver ||= typer.type_of(node.receiver)
    args = (node.arguments&.arguments || []).map { |argument| typer.type_of(argument) }
    cc(receiver: receiver, method_name: node.name, args: args, block_type: nil, environment: scope.environment,
       call_node: node, scope: scope)
  end

  def answer(...) = described_class.try_call(site(...), typer)

  describe ".try_call" do
    it "types the target as the call it names: by the dispatcher, a project `def`, or a project `def self.`" do
      expect(answer(8).describe).to eq('"A"')
      expect(answer(5).describe).to eq('"box"')
      expect(answer(6).describe).to eq("3")
      expect(answer(7).describe).to eq('"reg"')
    end

    it "takes the receiver from the site, not from the call node" do
      expect(answer(5, receiver: combinator.singleton_of("Reg")).describe).to eq('"reg"')
    end

    # Issue #3080 — `Wire#send` is a method of its own, so `w.send(:label)` is typed from its body; `public_send` is
    # another method and still reads as its target, `Wire#label`.
    it "answers a receiver's own `send` from its body, ahead of the target, and only for `send`" do
      expect(answer(9).describe).to eq(":sent")
      expect(answer(10).describe).to eq(":wired")
    end

    it "answers nothing for a selector that is not a literal symbol, a block, a splat, or a call that is no `send`" do
      expect([11, 12, 13, 14].map { |index| answer(index) }).to all(be_nil)
    end
  end

  it "exposes the rung alone, and hides the rest" do
    expect(described_class.singleton_class.public_instance_methods(false)).to contain_exactly(:try_call)
    expect { described_class.literal_send_arguments(statements[5]) }.to raise_error(NoMethodError, /private/)
  end
end
