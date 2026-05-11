# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::TypeNodeResolver do
  describe "default behaviour" do
    it "returns nil from #resolve for any node + scope (safe fall-through)" do
      node = Rigor::TypeNode::Identifier.new(name: "Pick")
      expect(described_class.new.resolve(node, nil)).to be_nil
    end

    it "returns nil for a Generic node as well" do
      arg = Rigor::TypeNode::Identifier.new(name: "T")
      node = Rigor::TypeNode::Generic.new(head: "Pick", args: [arg])
      expect(described_class.new.resolve(node, nil)).to be_nil
    end
  end

  describe "subclassing" do
    let(:resolver_class) do
      Class.new(described_class) do
        def resolve(node, _scope)
          return nil unless node.is_a?(Rigor::TypeNode::Generic) && node.head == "Pick"

          # placeholder slice-2 stub — slice 4 will wire pick_of[T, K].
          :pick_resolved_stub
        end
      end
    end

    it "lets subclasses return a non-nil result for matching nodes" do
      pick = Rigor::TypeNode::Generic.new(
        head: "Pick",
        args: [
          Rigor::TypeNode::Identifier.new(name: "Address"),
          Rigor::TypeNode::Identifier.new(name: "name")
        ]
      )
      expect(resolver_class.new.resolve(pick, nil)).to eq(:pick_resolved_stub)
    end

    it "falls through (returns nil) for non-matching nodes" do
      other = Rigor::TypeNode::Generic.new(head: "Omit", args: [])
      expect(resolver_class.new.resolve(other, nil)).to be_nil
    end
  end
end
