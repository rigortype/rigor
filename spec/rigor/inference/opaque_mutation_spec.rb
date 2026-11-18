# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/opaque_mutation"
require "rigor/scope"
require "rigor/type"

# Issue #3340 — the forms that hand a variable's object to code the engine cannot read. The end-to-end reading (the
# stale `non-empty-array` past each form) is `statement_evaluator/unspelled_content_mutation_spec.rb`; this file pins
# which call is which, and what the floor leaves alone.
RSpec.describe Rigor::Inference::OpaqueMutation do
  def call(source) = Prism.parse(source).value.statements.body.last

  def receiver_source(source) = described_class.opaque_receiver(call(source))&.slice

  describe ".opaque_receiver" do
    it "answers the receiver of a send whose name is computed" do
      expect(receiver_source("xs.send(name)")).to eq("xs")
      expect(receiver_source("xs.public_send(name, 1)")).to eq("xs")
      expect(receiver_source("xs.__send__(*args)")).to eq("xs")
    end

    it "answers nothing for a literal send, which is the call it makes, unless it names a mutator and takes a block" do
      expect(receiver_source("xs.send(:clear)")).to be_nil
      expect(receiver_source('xs.send("size")')).to be_nil
      expect(receiver_source("xs.send(:each) { |x| x }")).to be_nil
      expect(receiver_source("xs.send(:map!) { |x| x }")).to eq("xs")
    end

    it "answers nothing for a send on self, or one that passes only a block" do
      expect(receiver_source("send(name)")).to be_nil
      expect(receiver_source("self.send(name)")).to be_nil
      expect(receiver_source("xs.send(&blk)")).to be_nil
    end

    it "answers the receiver of an instance_eval whose literal block mutates self" do
      expect(receiver_source("xs.instance_eval { clear }")).to eq("xs")
      expect(receiver_source("xs.instance_exec { self.pop }")).to eq("xs")
      expect(receiver_source("xs.instance_eval { [1].each { push(1) } }")).to eq("xs")
      expect(receiver_source("xs.instance_eval { send(name) }")).to eq("xs")
    end

    it "answers nothing for an instance_eval whose literal block only reads self or mutates something else" do
      expect(receiver_source("xs.instance_eval { size }")).to be_nil
      expect(receiver_source("xs.instance_eval { ys.clear }")).to be_nil
      expect(receiver_source("xs.instance_eval { def wipe = clear }")).to be_nil
    end

    it "answers the receiver of an instance_eval whose code the call does not show" do
      expect(receiver_source("xs.instance_eval(&blk)")).to eq("xs")
      expect(receiver_source("xs.instance_eval(code)")).to eq("xs")
    end

    it "answers the receiver of a Method object called at once under a computed name" do
      expect(receiver_source("xs.method(name).call")).to eq("xs")
      expect(receiver_source("xs.public_method(name).(1)")).to eq("xs")
      expect(receiver_source("xs.method(name)[1]")).to eq("xs")
    end

    it "answers nothing for a Method object under a literal name, or one not called at once" do
      expect(receiver_source("xs.method(:clear).call")).to be_nil
      expect(receiver_source("xs.method(name).owner")).to be_nil
      expect(receiver_source("m.call")).to be_nil
      expect(receiver_source("method(name).call")).to be_nil
    end
  end

  describe ".method_object_target" do
    it "reads a literal-named Method object called at once as the call it makes" do
      target = described_class.method_object_target(call("xs.method(:push).call(1, 2)"))
      expect([target.receiver.slice, target.name]).to eq(["xs", :push])
      expect(target.arguments.arguments.map(&:slice)).to eq(%w[1 2])
      expect(described_class.method_object_target(call('xs.public_method("clear").()')).name).to eq(:clear)
    end

    it "answers nothing for a computed name, a block, or a Method object any other way" do
      expect(described_class.method_object_target(call("xs.method(name).call"))).to be_nil
      expect(described_class.method_object_target(call("xs.method(:map!).call { |x| x }"))).to be_nil
      expect(described_class.method_object_target(call("xs.method(:clear).owner"))).to be_nil
      expect(described_class.method_object_target(call("xs.clear"))).to be_nil
    end
  end

  describe ".floor" do
    let(:combinator) { Rigor::Type::Combinator }

    def floored(type, source = "xs.send(name)")
      scope = Rigor::Scope.empty.with_local(:xs, type)
      described_class.floor(call("xs = name = nil\n#{source}"), scope).local(:xs)
    end

    it "gives a literal shape one unknown store" do
      tuple = combinator.tuple_of(combinator.constant_of(1), combinator.constant_of(2))
      expect(floored(tuple).describe).to eq("Array[Dynamic[Integer]]")
      expect(floored(combinator.constant_of("ab")).describe).to eq("String")
    end

    it "drops an empty witness" do
      strings = combinator.nominal_of("Array", type_args: [combinator.nominal_of("String")])
      witness = combinator.non_empty_array(combinator.nominal_of("String"))
      expect(floored(witness)).not_to eq(witness)
      expect(floored(witness).describe).not_to include("non-empty")
      expect(floored(strings)).to equal(strings)
    end

    it "leaves a nominal and a non-collection as they are" do
      integer = combinator.nominal_of("Integer")
      expect(floored(integer)).to equal(integer)
    end

    it "leaves every binding alone after a call that is none of the forms" do
      tuple = combinator.tuple_of(combinator.constant_of(1))
      expect(floored(tuple, "xs.send(:size)")).to equal(tuple)
      expect(floored(tuple, "xs.fetch(name)")).to equal(tuple)
    end
  end

  describe ".yielded" do
    it "floors the locals a yield passes, positionally or as a keyword's value, and no other" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of(1))
      scope = %i[a b c].reduce(Rigor::Scope.empty) { |acc, name| acc.with_local(name, tuple) }
      after = described_class.yielded(call("def m(a, b, c) = yield(a, key: b)").body.body.first, scope)
      expect(%i[a b c].map { |name| after.local(name).equal?(tuple) }).to eq([false, false, true])
    end
  end
end
