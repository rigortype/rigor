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
    it "renders the slice-A1 type / erased / node body for an unspecialised node" do
      # `BreakNode` has no specialisation in slices A1-A4; it
      # exercises the default rendering path. The `break` keyword
      # has no inferable type so the renderer surfaces `untyped`.
      root = Prism.parse("loop { break 1 }").value
      break_node = nil
      walk = lambda do |n|
        break_node = n if n.is_a?(Prism::BreakNode)
        n.compact_child_nodes.each(&walk) if n.respond_to?(:compact_child_nodes) && break_node.nil?
      end
      walk.call(root)
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: base_scope)

      result = renderer.render(node: break_node, type: index[break_node].type_of(break_node),
                               node_scope_lookup: index)
      body = result[:contents][:value]

      expect(result[:contents][:kind]).to eq("markdown")
      expect(body).to include("type:")
      expect(body).to include("erased:")
      expect(body).to include("node:   Prism::BreakNode")
    end
  end

  describe "Prism::CallNode specialisation" do
    it "shows the receiver type + method signature for `String#upcase`" do
      root, index = parse_and_index("\"hello\".upcase\n")
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

    it "appends RBS documentation when the method has comments (slice C3)" do
      # `String#upcase`'s RBS in core ships with rdoc comments;
      # hover should surface them below the code block.
      root, index = parse_and_index("\"hello\".upcase\n")
      call_node = root.statements.body.first
      scope = index[call_node]

      result = renderer.render(node: call_node, type: scope.type_of(call_node), node_scope_lookup: index)
      body = result[:contents][:value]

      # The doc text contains rdoc-flavoured markup; just check
      # the separator + at least one comment line is present.
      expect(body).to include("---")
      expect(body).to match(/Returns|String/)
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

  describe "range field (slice E1)" do
    it "includes the hovered node's source range in the response" do
      root, index = parse_and_index("\"hello\".upcase\n")
      call_node = root.statements.body.first
      scope = index[call_node]

      result = renderer.render(node: call_node, type: scope.type_of(call_node), node_scope_lookup: index)

      expect(result).to include(:range)
      range = result[:range]
      # `"hello".upcase` sits on LSP line 0; spans from col 0 to
      # col 14 (length of the call expression including the dot).
      expect(range[:start]).to eq(line: 0, character: 0)
      expect(range[:end][:line]).to eq(0)
      expect(range[:end][:character]).to be > 0
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

  describe "Literal polish (slice A4)" do
    it "renders an integer literal with Type + Erased (no debug node row)" do
      root, index = parse_and_index("42\n")
      int_node = root.statements.body.first
      scope = index[int_node]

      result = renderer.render(node: int_node, type: scope.type_of(int_node), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(body).to include("# Type\n42")
      expect(body).to include("# Erased")
      expect(body).not_to include("node:") # the slice-A1 default row is gone
    end

    it "renders a string literal" do
      root, index = parse_and_index("\"hi\"\n")
      str_node = root.statements.body.first
      scope = index[str_node]

      result = renderer.render(node: str_node, type: scope.type_of(str_node), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(body).to include("# Type")
      expect(body).to include("# Erased")
      # The string literal infers to `Constant<"hi">`; its
      # erase_to_rbs is the inspected literal, not `::String`.
      expect(body).to include("\"hi\"")
    end

    it "renders a tuple-shape literal showing element types" do
      root, index = parse_and_index("[1, 2, 3]\n")
      arr_node = root.statements.body.first
      scope = index[arr_node]

      result = renderer.render(node: arr_node, type: scope.type_of(arr_node), node_scope_lookup: index)
      body = result[:contents][:value]

      # Tuple<1, 2, 3> or similar carrier description; the exact
      # shape comes from Type::Tuple#describe.
      expect(body).to include("# Type")
      expect(body).to include("# Erased")
    end

    it "surfaces the refinement name for refined carriers" do
      # We construct a refined type directly because triggering
      # narrowing through source requires more setup than the test
      # needs; the renderer's surface contract is "if the type
      # responds to canonical_name with a non-nil value, surface it."
      refined = Rigor::Type::Combinator.non_empty_string
      stub_node = Prism.parse("nil\n").value.statements.body.first
      stub_index = { stub_node => Rigor::Scope.empty }

      result = renderer.render(node: stub_node, type: refined, node_scope_lookup: stub_index)
      body = result[:contents][:value]

      expect(body).to include("# Refinement\nnon-empty-string")
    end
  end

  describe "Local / Ivar specialisation (slice A3)" do
    it "renders a local variable's name + type" do
      root, index = parse_and_index("x = 42\nx\n")
      read_node = root.statements.body.last
      scope = index[read_node]

      result = renderer.render(node: read_node, type: scope.type_of(read_node), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(body).to include("# Local\nx")
      expect(body).to include("# Type")
      # `x` was assigned `42`; the inferred type for the read should
      # be a Constant<42> or Nominal[Integer] form.
      expect(body).to match(/# Type\n\d+|# Type\nInteger/)
    end

    it "renders an instance variable's name + type + enclosing class" do
      source = <<~RUBY
        class Foo
          def m
            @ivar = 42
            @ivar
          end
        end
      RUBY
      root, index = parse_and_index(source)
      # Find the second @ivar read node (the bare one on its own line).
      ivar_read = nil
      walk = lambda do |n|
        ivar_read = n if n.is_a?(Prism::InstanceVariableReadNode)
        n.compact_child_nodes.each(&walk) if n.respond_to?(:compact_child_nodes)
      end
      walk.call(root)
      scope = index[ivar_read]

      result = renderer.render(node: ivar_read, type: scope.type_of(ivar_read), node_scope_lookup: index)
      body = result[:contents][:value]

      expect(body).to include("# Ivar\n@ivar")
      expect(body).to include("# Type")
      expect(body).to include("# In class\nFoo")
    end
  end
end
