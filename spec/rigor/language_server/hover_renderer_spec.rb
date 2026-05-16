# frozen_string_literal: true

require "prism"
require "rigor/language_server/hover_renderer"
require "rigor/environment"
require "rigor/scope"
require "rigor/inference/scope_indexer"
require "rigor/type/combinator"

RSpec.describe Rigor::LanguageServer::HoverRenderer do
  let(:renderer) { described_class.new }
  let(:environment) { Rigor::Environment.for_project }
  let(:base_scope) { Rigor::Scope.empty(environment: environment) }

  def parse_and_index(source)
    parsed = Prism.parse(source).value
    [parsed, Rigor::Inference::ScopeIndexer.index(parsed, default_scope: base_scope)]
  end

  describe "default body (unspecialised nodes)" do
    it "mirrors the LSP v1 slice-5 output for a literal integer" do
      root, index = parse_and_index("42\n")
      int_node = root.statements.body.first
      scope = index[int_node]

      result = renderer.render(node: int_node, type: scope.type_of(int_node), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(result[:contents][:kind]).to eq("markdown")
      expect(body).to include("type:")
      expect(body).to include("erased:")
      expect(body).to include("node:   Prism::IntegerNode")
    end
  end

  describe "Prism::CallNode specialisation" do
    it "shows the receiver type + method signature for `String#upcase`" do
      root, index = parse_and_index('"hello".upcase' "\n")
      call_node = root.statements.body.first
      scope = index[call_node]

      result = renderer.render(node: call_node, type: scope.type_of(call_node), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(body).to include("# Receiver")
      expect(body).to include("String")
      expect(body).to include("# Method")
      expect(body).to include("String#upcase:")
      expect(body).to include("# Return")
    end

    it "falls back to the default body for implicit-`self` calls (no receiver)" do
      # `foo` with no receiver — implicit self call. Slice 1 only
      # specialises calls with explicit receivers; later slices may
      # add implicit-self via the enclosing class lookup.
      root, index = parse_and_index("foo\n")
      call_node = root.statements.body.first
      scope = index[call_node]

      result = renderer.render(node: call_node, type: scope.type_of(call_node), node_scope_lookup: index)

      expect(result[:contents][:value]).to include("node:   Prism::CallNode")
    end

    it "falls back to the default body when the method isn't in the RBS env" do
      # `1.totally_made_up_method` — receiver type known (Integer)
      # but method doesn't resolve. Render falls through to the
      # default body rather than emitting a bogus signature.
      root, index = parse_and_index("1.totally_made_up_method\n")
      call_node = root.statements.body.first
      scope = index[call_node]

      result = renderer.render(node: call_node, type: scope.type_of(call_node), node_scope_lookup: index)

      expect(result[:contents][:value]).to include("node:   Prism::CallNode")
    end

    it "handles a singleton-method call (`String.new`) via singleton_method_definition" do
      root, index = parse_and_index("String.new\n")
      call_node = root.statements.body.first
      scope = index[call_node]

      result = renderer.render(node: call_node, type: scope.type_of(call_node), node_scope_lookup: index)
      body = result[:contents][:value]

      # Should surface receiver class + the dot separator that marks
      # a singleton dispatch.
      expect(body).to include("String")
      expect(body).to include("String.new:")
    end
  end
end
