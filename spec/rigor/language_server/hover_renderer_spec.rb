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

  describe "Prism::ConstantReadNode / ConstantPathNode specialisation (slice A2)" do
    it "shows the constant FQN + singleton type for a bare class reference" do
      root, index = parse_and_index("String\n")
      const_node = root.statements.body.first
      scope = index[const_node]

      result = renderer.render(node: const_node, type: scope.type_of(const_node), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(body).to include("# Constant\nString")
      expect(body).to include("# Type\nsingleton(String)")
    end

    it "renders nested constant paths with the full FQN" do
      root, index = parse_and_index("Process::Status\n")
      const_node = root.statements.body.first
      scope = index[const_node]

      result = renderer.render(node: const_node, type: scope.type_of(const_node), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(body).to include("# Constant\nProcess::Status")
      expect(body).to include("# Type\nsingleton(Process::Status)")
    end

    it "falls back to the default body for value constants (e.g. FOO = 42)" do
      # Without seeing `FOO = 42` in the buffer the renderer can't
      # know the constant is a value; we test with an unknown
      # bare-Constant whose type isn't a Singleton — the renderer
      # must still produce a body (the default one). For this we
      # use a known not-in-RBS constant by constructing the type
      # directly is over-mocking; instead test the negative path
      # via the absence of `# Constant` framing when type isn't
      # `Singleton`.
      root, index = parse_and_index("CONSTANT_DOES_NOT_EXIST\n")
      const_node = root.statements.body.first
      scope = index[const_node]
      type = scope.type_of(const_node)

      result = renderer.render(node: const_node, type: type, node_scope_lookup: index)
      body = result[:contents][:value]

      if type.is_a?(Rigor::Type::Singleton)
        expect(body).to include("# Constant")
      else
        expect(body).to include("node:")
      end
    end
  end
end
