# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::ExpressionTyper do
  let(:scope) { Rigor::Scope.empty }

  def parse_expression(source, scopes: [])
    Prism.parse(source, scopes: scopes).value.statements.body.first
  end

  describe "literal nodes" do
    it "types integer literals as Constant<Integer> and erases to the RBS literal form" do
      type = scope.type_of(parse_expression("42"))
      expect(type.describe).to eq("42")
      expect(type.erase_to_rbs).to eq("42")
    end

    it "types float literals as Constant<Float> and widens at erasure (RBS has no Float literal)" do
      type = scope.type_of(parse_expression("2.5"))
      expect(type.describe).to eq("2.5")
      expect(type.erase_to_rbs).to eq("Float")
    end

    it "types string literals as Constant<String> and erases to the RBS literal form" do
      type = scope.type_of(parse_expression('"hi"'))
      expect(type.describe).to eq('"hi"')
      expect(type.erase_to_rbs).to eq('"hi"')
    end

    it "types symbol literals as Constant<Symbol> and erases to the RBS literal form" do
      type = scope.type_of(parse_expression(":foo"))
      expect(type.describe).to eq(":foo")
      expect(type.erase_to_rbs).to eq(":foo")
    end

    it "types true/false/nil as their constant carriers" do
      expect(scope.type_of(parse_expression("true")).describe).to eq("true")
      expect(scope.type_of(parse_expression("false")).describe).to eq("false")
      expect(scope.type_of(parse_expression("nil")).describe).to eq("nil")
    end

    it "types __FILE__ as `non-empty-string` (erases to String)" do
      type = scope.type_of(parse_expression("__FILE__"))
      expect(type.describe).to eq("non-empty-string")
      expect(type.erase_to_rbs).to eq("String")
    end

    it "types __LINE__ as `positive-int` (erases to Integer)" do
      type = scope.type_of(parse_expression("__LINE__"))
      expect(type.describe).to eq("positive-int")
      expect(type.erase_to_rbs).to eq("Integer")
    end

    it "types backtick xstrings as Nominal[String]" do
      expect(scope.type_of(parse_expression("`echo hi`")).erase_to_rbs).to eq("String")
    end

    it "types %x{...} xstrings as Nominal[String]" do
      expect(scope.type_of(parse_expression("%x{echo hi}")).erase_to_rbs).to eq("String")
    end

    it "types interpolated %x{} xstrings as Nominal[String]" do
      source = "%x{echo \#{1}}"
      expect(scope.type_of(parse_expression(source)).erase_to_rbs).to eq("String")
    end

    it "types END { } (PostExecutionNode) as nil" do
      expect(scope.type_of(parse_expression("END { 1 }")).describe).to eq("nil")
    end

    it "passes through ImplicitNode (shorthand hash value)" do
      hash_node = parse_expression("{ y: }", scopes: [[:y]])
      implicit = hash_node.elements.first.value
      bound = scope.with_local(:y, Rigor::Type::Combinator.constant_of(7))
      expect(bound.type_of(implicit).describe).to eq("7")
    end
  end

  describe "local variables" do
    it "fails soft to Dynamic[Top] for unbound reads" do
      node = parse_expression("x", scopes: [[:x]])
      type = scope.type_of(node)
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end

    it "looks up bound locals" do
      bound = scope.with_local(:x, Rigor::Type::Combinator.constant_of(1))
      node = parse_expression("x", scopes: [[:x]])
      type = bound.type_of(node)
      expect(type.describe).to eq("1")
    end

    it "types a write expression as the value's type" do
      type = scope.type_of(parse_expression("y = 7"))
      expect(type.describe).to eq("7")
    end

    it "does not mutate the receiver scope on a write expression" do
      _ = scope.type_of(parse_expression("y = 7"))
      expect(scope.local(:y)).to be_nil
    end

    it "types `it` (Ruby 3.4) as the binding installed under :it" do
      bound = scope.with_local(:it, Rigor::Type::Combinator.constant_of(42))
      it_read = Prism.parse("[1].each { it }").value.statements.body.first.block.body.body.first
      expect(it_read).to be_a(Prism::ItLocalVariableReadNode)
      expect(bound.type_of(it_read).describe).to eq("42")
    end

    it "fails soft on unbound `it` to Dynamic[Top]" do
      it_read = Prism.parse("[1].each { it }").value.statements.body.first.block.body.body.first
      expect(scope.type_of(it_read)).to equal(Rigor::Type::Combinator.untyped)
    end
  end

  describe "regex back-references and `defined?`" do
    let(:string_or_nil) do
      Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("String"),
        Rigor::Type::Combinator.constant_of(nil)
      )
    end

    it "types `defined?(expr)` as String | nil" do
      type = scope.type_of(parse_expression("defined?(y)"))
      expect(type).to eq(string_or_nil)
    end

    it "types numbered references ($1, $2, ...) as String | nil" do
      type = scope.type_of(parse_expression("$1"))
      expect(type).to eq(string_or_nil)
    end

    it "types back-references ($&, $+, ...) as String | nil" do
      type = scope.type_of(parse_expression("$&"))
      expect(type).to eq(string_or_nil)
    end
  end

  describe "pattern-matching expressions" do
    it "types `expr in pattern` as a true/false union" do
      type = scope.type_of(parse_expression("x in Integer", scopes: [[:x]]))
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to contain_exactly(
        Rigor::Type::Combinator.constant_of(true),
        Rigor::Type::Combinator.constant_of(false)
      )
    end

    it "types `expr => pattern` as Constant[nil]" do
      type = scope.type_of(parse_expression("x => Integer", scopes: [[:x]]))
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
    end
  end

  describe "shallow array literals" do
    it "types empty arrays as the empty Tuple[] carrier (v0.0.6)" do
      # `[]` resolves to `Tuple[]` so the per-element block fold
      # can concatenate across all-empty positions like
      # `[1, 2].flat_map { |_| [] }`. The empty tuple erases to
      # the RBS tuple form `[]` (a valid RBS literal for the
      # empty-tuple type); use `Tuple#describe` rather than the
      # erasure form for round-trip checks.
      type = scope.type_of(parse_expression("[]"))
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([])
    end

    it "types non-empty arrays as Tuple[T1, T2, ...] (Slice 5 phase 1)" do
      type = scope.type_of(parse_expression('[1, "hi", :foo]'))
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq(
        [
          Rigor::Type::Combinator.constant_of(1),
          Rigor::Type::Combinator.constant_of("hi"),
          Rigor::Type::Combinator.constant_of(:foo)
        ]
      )
    end

    it "falls back to Nominal[Array, [Elem]] when an element is splatted" do
      array_int = Rigor::Type::Combinator.nominal_of(
        Array,
        type_args: [Rigor::Type::Combinator.nominal_of(Integer)]
      )
      bound = scope.with_local(:xs, array_int)
      type = bound.type_of(parse_expression("[*xs, 1]", scopes: [[:xs]]))
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
      expect(type.type_args.size).to eq(1)
    end
  end

  describe "LHS-only target nodes (non-value positions)" do
    # `*TargetNode` kinds appear only on the left of destructuring assignments, in pattern bodies, or as inner slots of
    # block parameters. They have no value to extract; the typer recognises them so the coverage scanner / `--explain`
    # stream stops counting them as fail-soft fallbacks. Binding the inner names back into the scope is
    # `StatementEvaluator` / `MultiTargetBinder` / `BlockParameterBinder`'s concern, never `type_of`'s.
    def find_first(node, klass)
      return node if node.is_a?(klass)
      return nil unless node.respond_to?(:compact_child_nodes)

      node.compact_child_nodes.each do |child|
        found = find_first(child, klass)
        return found if found
      end
      nil
    end

    {
      Prism::MultiTargetNode => "a, (b, c) = 1, [2, 3]",
      Prism::InstanceVariableTargetNode => "@a, @b = 1, 2",
      Prism::ClassVariableTargetNode => "@@a, @@b = 1, 2",
      Prism::GlobalVariableTargetNode => "$a, $b = 1, 2",
      Prism::ConstantTargetNode => "A, B = 1, 2",
      Prism::ConstantPathTargetNode => "M::A, M::B = 1, 2",
      Prism::CallTargetNode => "x.a, x.b = 1, 2",
      Prism::IndexTargetNode => "h[:a], h[:b] = 1, 2"
    }.each do |node_class, source|
      it "types Prism::#{node_class.name.split('::').last} as Dynamic[Top] without recording a fallback" do
        program = Prism.parse(source).value
        target = find_first(program, node_class)
        expect(target).not_to be_nil, "expected to find a #{node_class} in #{source.inspect}"

        tracer = Rigor::Inference::FallbackTracer.new
        type = scope.type_of(target, tracer: tracer)

        expect(type).to equal(Rigor::Type::Combinator.untyped)
        expect(tracer).to be_empty
      end
    end
  end

  describe "fail-soft policy" do
    it "returns Dynamic[Top] for unrecognised nodes" do
      type = scope.type_of(parse_expression("foo()"))
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end

    it "never raises on supported Ruby surface" do
      %w[
        if true; 1; else; 2; end
        case 1; when Integer; :i; end
        def foo; 1; end
        Class.new
        @ivar
        $g
        ::Module
        1 + 2
      ].each do |source|
        node = parse_expression(source)
        expect { scope.type_of(node) }.not_to raise_error
      end
    end
  end

  describe "purity" do
    it "produces structurally equal results across calls" do
      node = parse_expression("[1, 2, 3]")
      first = scope.type_of(node)
      second = scope.type_of(node)
      expect(first).to eq(second)
    end
  end

  describe "virtual nodes" do
    it "round-trips a TypeNode wrapping a Constant" do
      inner = Rigor::Type::Combinator.constant_of(42)
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).to eq(inner)
    end

    it "round-trips a TypeNode wrapping a Nominal" do
      inner = Rigor::Type::Combinator.nominal_of(String)
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).to eq(inner)
    end

    it "round-trips a TypeNode wrapping Dynamic[Top]" do
      inner = Rigor::Type::Combinator.untyped
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).to equal(inner)
    end

    it "does not wrap or annotate the inner type" do
      inner = Rigor::Type::Combinator.nominal_of(Integer)
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).not_to be_a(Rigor::Type::Dynamic)
    end

    it "fails soft on an unknown synthetic node" do
      unknown_node_class = Class.new do
        include Rigor::AST::Node

        def initialize
          freeze
        end
      end
      type = scope.type_of(unknown_node_class.new)
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end
  end

  describe "fallback tracer" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "records nothing when no fallback occurs" do
      scope.type_of(parse_expression("42"), tracer: tracer)
      expect(tracer).to be_empty
    end

    it "records a Prism-family fallback for unrecognised Prism nodes" do
      node = parse_expression("foo()")
      type = scope.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.size).to eq(1)
      event = tracer.events.first
      expect(event.node_class).to eq(node.class)
      expect(event.family).to eq(:prism)
      expect(event.inner_type).to equal(Rigor::Type::Combinator.untyped)
      expect(event.location).not_to be_nil
    end

    it "records a virtual-family fallback for unknown synthetic nodes" do
      unknown_node_class = Class.new do
        include Rigor::AST::Node

        def initialize
          freeze
        end
      end
      type = scope.type_of(unknown_node_class.new, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.size).to eq(1)
      event = tracer.events.first
      expect(event.family).to eq(:virtual)
      expect(event.location).to be_nil
    end

    it "records nested fallbacks discovered while traversing children" do
      # ArrayNode is recognised in slice 1; its element CallNode is not.
      node = parse_expression("[foo(), 1]")
      scope.type_of(node, tracer: tracer)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "does not change the type returned regardless of tracer presence" do
      node = parse_expression("foo()")
      with_tracer = scope.type_of(node, tracer: tracer)
      without_tracer = scope.type_of(node)
      expect(with_tracer).to eq(without_tracer)
    end

    it "leaves recognised TypeNode synthetic nodes untraced" do
      type_node = Rigor::AST::TypeNode.new(Rigor::Type::Combinator.constant_of(1))
      scope.type_of(type_node, tracer: tracer)
      expect(tracer).to be_empty
    end
  end

  describe "method dispatch (Slice 2)" do
    it "folds Constant Integer + Constant Integer into Constant" do
      type = scope.type_of(parse_expression("1 + 2"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(3)
    end

    it "folds nested arithmetic expressions" do
      type = scope.type_of(parse_expression("(1 + 2) * 3"))

      expect(type.value).to eq(9)
    end

    it "folds string concatenation between Constant Strings" do
      type = scope.type_of(parse_expression('"foo" + "bar"'))

      expect(type.value).to eq("foobar")
    end

    it "folds symbol equality into Constant boolean" do
      type = scope.type_of(parse_expression(":a == :a"))

      expect(type.value).to be(true)
    end

    it "falls back to Dynamic[Top] for calls with no receiver" do
      tracer = Rigor::Inference::FallbackTracer.new
      node = parse_expression("foo()")
      type = scope.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "falls back when neither the constant folder nor RBS knows the method" do
      tracer = Rigor::Inference::FallbackTracer.new
      node = parse_expression("[1, 2].this_method_does_not_exist")
      type = scope.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "treats ArgumentsNode as a non-value position (Dynamic[Top], no fallback)" do
      tracer = Rigor::Inference::FallbackTracer.new
      call_node = parse_expression("foo(1, 2)")
      arguments_node = call_node.arguments

      type = scope.type_of(arguments_node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end
  end

  describe "method dispatch (Slice 4: RBS-backed)" do
    it "resolves Integer#succ on a Constant receiver via unary fold (v0.0.3 C)" do
      # `1.succ` folds to `Constant[2]`; the RBS-widened `Nominal[Integer]` answer is exercised via non-constant
      # receivers in dispatch_spec.
      type = scope.type_of(parse_expression("1.succ"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(2)
    end

    it "resolves Constant#to_s via unary fold to a Constant[String] (v0.0.3 C)" do
      type = scope.type_of(parse_expression("3.to_s"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq("3")
    end

    it "resolves Array#length on a Nominal[Array] receiver" do
      # Returns the precise Tuple length as a Constant rather than the projected Nominal[Integer]; the carrier still
      # erases to Integer.
      type = scope.type_of(parse_expression("[1, 2, 3].length"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "resolves String#upcase on a Constant[String] receiver via unary fold (v0.0.3 C)" do
      type = scope.type_of(parse_expression('"hi".upcase'))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq("HI")
    end

    it "resolves bool predicates more precisely than RBS when the receiver is a constant (v0.0.3 C)" do
      # `1.zero?` folds to `Constant[false]` — the unary constant-folding catalogue wins over the RBS-widened
      # `Union[Constant[true], Constant[false]]`. When the receiver is *not* a constant, the union representation is
      # still the answer; the broader widening behaviour is exercised below.
      type = scope.type_of(parse_expression("1.zero?"))
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to be(false)

      union_type = scope.type_of(parse_expression("def f(n); n.zero?; end"))
      # The DefNode's type isn't the body's bool, but the widened-union proof lives in the dedicated unary tests in
      # `constant_folding_spec.rb`.
      expect(union_type).not_to be_nil
    end

    it "constant folding still wins over RBS dispatch when applicable" do
      type = scope.type_of(parse_expression("1 + 2"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(3)
    end

    it "honors Dynamic-receiver dispatch by unwrapping the static facet" do
      dyn_int = Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of(Integer))
      bound = scope.with_local(:x, dyn_int)
      type = bound.type_of(parse_expression("x.succ", scopes: [[:x]]))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "unions return types when the receiver is a Union" do
      union_type = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of(Integer),
        Rigor::Type::Combinator.nominal_of(String)
      )
      bound = scope.with_local(:x, union_type)
      type = bound.type_of(parse_expression("x.to_s", scopes: [[:x]]))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("String")
    end

    it "falls back when one Union member does not implement the method" do
      tracer = Rigor::Inference::FallbackTracer.new
      union_type = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of(Integer),
        Rigor::Type::Combinator.nominal_of(String)
      )
      bound = scope.with_local(:x, union_type)
      node = parse_expression("x.bit_length", scopes: [[:x]])

      type = bound.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "resolves an RBS-only constant (Encoding::Converter) as Singleton" do
      type = scope.type_of(parse_expression("Encoding::Converter"))

      expect(type).to be_a(Rigor::Type::Singleton)
      expect(type.class_name).to eq("Encoding::Converter")
    end

    it "silently propagates Dynamic when the receiver is Dynamic[Top] and no rule matches" do
      tracer = Rigor::Inference::FallbackTracer.new
      bound = scope.with_local(:x, Rigor::Type::Combinator.untyped)
      type = bound.type_of(parse_expression("x.something_unknown", scopes: [[:x]]), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).not_to include(Prism::CallNode)
    end
  end

  describe "constant resolution (Slice 2 strengthening, Slice 4 phase 2b semantics)" do
    it "resolves a registered Slice 1 built-in via ConstantReadNode as Singleton" do
      type = scope.type_of(parse_expression("Integer"))

      expect(type).to be_a(Rigor::Type::Singleton)
      expect(type.class_name).to eq("Integer")
    end

    it "resolves Slice 2 built-ins like Hash and StandardError as Singleton" do
      hash_type = scope.type_of(parse_expression("Hash"))
      err_type = scope.type_of(parse_expression("StandardError"))

      expect(hash_type).to be_a(Rigor::Type::Singleton)
      expect(err_type).to be_a(Rigor::Type::Singleton)
      expect(hash_type.class_name).to eq("Hash")
      expect(err_type.class_name).to eq("StandardError")
    end

    it "falls back to Dynamic[Top] for unknown ConstantReadNode names" do
      tracer = Rigor::Inference::FallbackTracer.new
      type = scope.type_of(parse_expression("Foo"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::ConstantReadNode)
    end

    it "resolves a top-level ConstantPathNode (`::Integer`) as Singleton" do
      type = scope.type_of(parse_expression("::Integer"))

      expect(type).to be_a(Rigor::Type::Singleton)
      expect(type.class_name).to eq("Integer")
    end

    it "falls back to Dynamic[Top] for unregistered ConstantPathNode" do
      tracer = Rigor::Inference::FallbackTracer.new
      type = scope.type_of(parse_expression("Foo::Bar"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::ConstantPathNode)
    end

    describe "lexical constant lookup (Slice A constant-walk)" do
      it "resolves a ConstantReadNode using the surrounding class path" do
        # Inside `Rigor::CLI::Foo`, a bare `Integer` reference still resolves through the top-level fallback.
        cli_self = Rigor::Type::Combinator.singleton_of("Rigor::CLI::Foo")
        bound = scope.with_self_type(cli_self)
        type = bound.type_of(parse_expression("Integer"))
        expect(type).to be_a(Rigor::Type::Singleton)
        expect(type.class_name).to eq("Integer")
      end

      it "resolves a ConstantPathNode by stripping the lexical prefix one segment at a time" do
        # Inside a hypothetical `IO::SomeNested`, the bare reference `Comparable` (a top-level RBS-core module) still
        # resolves. The walk tries `IO::SomeNested::Comparable` and `IO::Comparable` first (both miss) before falling
        # through to bare `Comparable`.
        nested_self = Rigor::Type::Combinator.singleton_of("IO::SomeNested")
        bound = scope.with_self_type(nested_self)
        type = bound.type_of(parse_expression("Comparable"))
        expect(type).to be_a(Rigor::Type::Singleton)
        expect(type.class_name).to eq("Comparable")
      end

      it "prefers the lexically-qualified candidate when one matches the surrounding path" do
        # `Errno::ENOENT` is RBS-core. Inside `Errno::SomeFakeNested`, a bare `ENOENT` reference walks via
        # `Errno::SomeFakeNested::ENOENT` (miss) → `Errno::ENOENT` (hit).
        nested_self = Rigor::Type::Combinator.singleton_of("Errno::SomeFakeNested")
        bound = scope.with_self_type(nested_self)
        type = bound.type_of(parse_expression("ENOENT"))
        expect(type).to be_a(Rigor::Type::Singleton)
        expect(type.class_name).to eq("Errno::ENOENT")
      end

      it "prefers the most-specific candidate over the bare name when both exist" do
        # `Integer` exists at top level. From inside a class whose path joined to `Integer` would coincidentally match
        # an already-known nominal, the most-specific candidate wins. Here we use a synthetic case that forces the bare
        # match because no Rigor::CLI::Integer is known: Integer still resolves (the bare candidate is reached after the
        # qualified ones miss).
        cli_self = Rigor::Type::Combinator.singleton_of("Rigor::CLI::Foo")
        bound = scope.with_self_type(cli_self)
        type = bound.type_of(parse_expression("Integer"))
        expect(type.class_name).to eq("Integer")
      end

      it "falls back to Dynamic[Top] when no lexical candidate matches" do
        tracer = Rigor::Inference::FallbackTracer.new
        cli_self = Rigor::Type::Combinator.singleton_of("Rigor::CLI::Foo")
        bound = scope.with_self_type(cli_self)
        type = bound.type_of(parse_expression("DefinitelyUnknownConstant"), tracer: tracer)
        expect(type).to equal(Rigor::Type::Combinator.untyped)
        expect(tracer.kinds).to include(Prism::ConstantReadNode)
      end

      it "preserves the pre-walk behaviour at top-level (no self_type set)" do
        # No self_type → only the bare candidate is tried.
        type = scope.type_of(parse_expression("Integer"))
        expect(type).to be_a(Rigor::Type::Singleton)
      end

      it "resolves user-defined classes through Scope#discovered_classes (Slice 7 phase 7)" do
        bound = scope.with_discovery(
          scope.discovery.with(
            discovered_classes: { "Account" => Rigor::Type::Combinator.singleton_of("Account") }.freeze
          )
        )
        type = bound.type_of(parse_expression("Account"))
        expect(type).to be_a(Rigor::Type::Singleton)
        expect(type.class_name).to eq("Account")
      end

      it "resolves in-source constant values through Scope#in_source_constants (Slice 7 phase 9)" do
        constants = { "BUCKETS" => Rigor::Type::Combinator.constant_of(:hello) }.freeze
        bound = scope.with_discovery(scope.discovery.with(in_source_constants: constants))
        type = bound.type_of(parse_expression("BUCKETS"))
        expect(type).to eq(Rigor::Type::Combinator.constant_of(:hello))
      end

      it "in-source value overrides an RBS constant decl of the same name" do
        # Sanity: the RBS constant lookup would normally win; the in-source map takes precedence per Ruby's runtime
        # semantics (user code is the authoritative source for its own constants).
        constants = { "Float::INFINITY" => Rigor::Type::Combinator.constant_of(:overridden) }.freeze
        bound = scope.with_discovery(scope.discovery.with(in_source_constants: constants))
        type = bound.type_of(parse_expression("Float::INFINITY"))
        expect(type).to eq(Rigor::Type::Combinator.constant_of(:overridden))
      end

      it "dispatches a Kernel intrinsic on top-level implicit-self calls (Slice 7 phase 10)" do
        project = Rigor::Scope.empty(environment: Rigor::Environment.for_project)
        type = project.type_of(parse_expression("require_relative('foo')"))
        expect(type).not_to equal(Rigor::Type::Combinator.untyped)
      end

      it "returns Nominal[T] from `Singleton[T].new` for user-defined classes" do
        bound = scope.with_discovery(
          scope.discovery.with(
            discovered_classes: { "ScanAccumulator" => Rigor::Type::Combinator.singleton_of("ScanAccumulator") }.freeze
          )
        )
        type = bound.type_of(parse_expression("ScanAccumulator.new"))
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("ScanAccumulator")
      end

      it "resolves a non-class constant declared in RBS through Environment#constant_for_name" do
        # `Rigor::Analysis::FactStore::BUCKETS` is declared in sig/rigor/analysis/fact_store.rbs as Array[bucket].
        # singleton_for_name MUST miss (BUCKETS is not a class) and constant_for_name MUST take over.
        project_env = Rigor::Environment.for_project
        project_scope = Rigor::Scope.empty(environment: project_env)
        type = project_scope.type_of(parse_expression("Rigor::Analysis::FactStore::BUCKETS"))
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Array")
      end

      it "resolves the same constant through the lexical walk from inside FactStore" do
        # Inside Rigor::Analysis::FactStore the bare `BUCKETS` reference walks the candidate list and lands on the
        # qualified `Rigor::Analysis::FactStore::BUCKETS` decl.
        project_env = Rigor::Environment.for_project
        inner_self = Rigor::Type::Combinator.singleton_of("Rigor::Analysis::FactStore")
        bound = Rigor::Scope.empty(environment: project_env).with_self_type(inner_self)
        type = bound.type_of(parse_expression("BUCKETS"))
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Array")
      end
    end

    it "types ConstantWriteNode as the rvalue's type" do
      type = scope.type_of(parse_expression("FOO = 42"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(42)
    end
  end

  describe "class-method dispatch (Slice 4 phase 2b)" do
    it "resolves Integer.sqrt(4) as Nominal[Integer] via singleton dispatch" do
      type = scope.type_of(parse_expression("Integer.sqrt(4)"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "resolves Array.new(3) as Tuple[nil, nil, nil] via singleton dispatch (v0.0.7)" do
      # `Array.new(n)` lifts to a per-position `Tuple[Constant[nil] * n]` carrier when `n` is a small
      # `Constant<Integer>`. Oversize `n` falls back to `Nominal[Array]`.
      type = scope.type_of(parse_expression("Array.new(3)"))

      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([Rigor::Type::Combinator.constant_of(nil)] * 3)
    end

    it "falls back to Nominal[Array] for an oversize Array.new(n)" do
      type = scope.type_of(parse_expression("Array.new(1000)"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
    end

    it "resolves Array.new(2) { \"s\" } as Tuple[\"s\", \"s\"] from the block's return (#317)" do
      # The block-bearing `(int size) { (Integer index) -> E } -> void` overload of
      # `Array#initialize` fills every slot from the block's return type, NOT from the
      # two-arg `(int size, ?E default_value)` overload's implicit `nil` default — those two
      # overloads are mutually exclusive at a real call site.
      type = scope.type_of(parse_expression("Array.new(2) { \"s\" }"))

      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([Rigor::Type::Combinator.constant_of("s")] * 2)
    end

    it "resolves Array.new(3) { |i| i * 2 } as Tuple[Integer, Integer, Integer] (block with index param)" do
      type = scope.type_of(parse_expression("Array.new(3) { |i| i * 2 }"))

      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([Rigor::Type::Combinator.nominal_of("Integer")] * 3)
    end

    it "Array.new(2) (no block) still fills with Constant[nil] elements" do
      # Must-still-fire control: without a block, the two-arg overload's `nil` default
      # genuinely applies, so a downstream `.upcase` on an element genuinely is an error.
      type = scope.type_of(parse_expression("Array.new(2)"))

      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([Rigor::Type::Combinator.constant_of(nil)] * 2)
    end

    it "Hash.new(0) lifts to Hash[untyped, Integer] (B9 default-arg fold)" do
      type = scope.type_of(parse_expression("Hash.new(0)"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Hash")
      expect(type.type_args[1]).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "a Hash.new(0) read of any key surfaces the default's type" do
      read = scope.type_of(parse_expression("Hash.new(0)[:missing]"))

      expect(read).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "Hash.new (no default) keeps the bare Nominal[Hash] answer" do
      type = scope.type_of(parse_expression("Hash.new"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Hash")
      expect(type.type_args).to(satisfy { |a| a.nil? || a.empty? })
    end

    it "Hash.new { block } declines (no value type at the :new site)" do
      type = scope.type_of(parse_expression("Hash.new { |h, k| k }"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Hash")
      expect(type.type_args).to(satisfy { |a| a.nil? || a.empty? })
    end

    it "Range.new(1, 5) lifts to Constant[1..5]" do
      type = scope.type_of(parse_expression("Range.new(1, 5)"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(1..5)
    end

    it "Range.new(1, 5, true) lifts to Constant[1...5] (exclusive)" do
      type = scope.type_of(parse_expression("Range.new(1, 5, true)"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(1...5)
    end

    it "Range.new(\"a\", \"z\") lifts to Constant[\"a\"..\"z\"]" do
      type = scope.type_of(parse_expression("Range.new(\"a\", \"z\")"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq("a".."z")
    end

    it "Range.new with a dynamic endpoint falls back to Nominal[Range]" do
      type = scope.type_of(parse_expression("Range.new(rand.to_i, 10)"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Range")
    end

    it "Integer.new resolves to Nominal[Integer] via inherited Class#new" do
      type = scope.type_of(parse_expression("Integer.new"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "Integer.name resolves to Nominal[String] via Module#name" do
      type = scope.type_of(parse_expression("Integer.name"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("String")
    end

    it "Singleton[Foo] for an unknown method falls back to Dynamic[Top]" do
      tracer = Rigor::Inference::FallbackTracer.new
      type = scope.type_of(
        parse_expression("Integer.this_class_method_does_not_exist"),
        tracer: tracer
      )

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::CallNode)
    end
  end

  describe "overload selection (Slice 4 phase 2c)" do
    it "selects the 1-arg overload of Array#first based on arity, on a non-Tuple receiver" do
      # A genuine `Array[Elem]` receiver (not a literal Tuple carrier) still routes through
      # `OverloadSelector`'s arity-based dispatch to the `(::int n) -> ::Array[Elem]` overload, which
      # erases to `Nominal[Array]`. `ShapeDispatch` only claims `first(n)` for a `Type::Tuple` receiver
      # (see the sibling example below), so a plain `Nominal[Array]` local still exercises this path.
      array_int = Rigor::Type::Combinator.nominal_of(Array, type_args: [Rigor::Type::Combinator.nominal_of(Integer)])
      bound = scope.with_local(:xs, array_int)
      type = bound.type_of(parse_expression("xs.first(2)", scopes: [[:xs]]))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
    end

    it "folds `first(n)` on a literal Tuple to the precise sub-Tuple (#121) instead of the wide overload" do
      # `[1, 2, 3]` is a `Tuple[Constant…]` carrier, so `ShapeDispatch` claims `first(n)` before
      # `OverloadSelector` ever sees the call — see `tuple_first_n` in `shape_dispatch.rb`.
      type = scope.type_of(parse_expression("[1, 2, 3].first(2)"))

      expect(type).to eq(Rigor::Type::Combinator.tuple_of(
                           Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of(2)
                         ))
    end

    it "still resolves the 0-arg overload of Array#first" do
      # `() -> Elem` — narrows to the precise first member of the Tuple shape rather than returning the projected `Elem`
      # union from the underlying `Array#first`.
      type = scope.type_of(parse_expression("[1, 2, 3].first"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "selects the 0-arg singleton overload of Array.new" do
      type = scope.type_of(parse_expression("Array.new"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
    end

    it "Hash literal carries HashShape{a: 1, b: 2} (Slice 5 phase 1)" do
      type = scope.type_of(parse_expression("{ a: 1, b: 2 }"))
      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs.keys).to eq(%i[a b])
      expect(type.pairs[:a]).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(type.pairs[:b]).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "Hash literal with numeric keys carries a HashShape with eql?-distinct 1 and 1.0" do
      type = scope.type_of(parse_expression("{ 1 => 1, 1 => 2, 1.0 => 3, 1.00 => 4 }"))
      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs.keys).to eq([1, 1.0])
      expect(type.pairs[1]).to eq(Rigor::Type::Combinator.constant_of(2))
      expect(type.pairs[1.0]).to eq(Rigor::Type::Combinator.constant_of(4))
    end

    it "Hash literal with true/false/nil keys carries a HashShape" do
      type = scope.type_of(parse_expression("{ true => 1, false => 2, nil => 3 }"))
      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs.keys).to eq([true, false, nil])
      expect(type.pairs[nil]).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "duplicate symbol keys are last-wins, matching the runtime" do
      type = scope.type_of(parse_expression("{ a: 1, a: 2 }"))
      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs).to eq({ a: Rigor::Type::Combinator.constant_of(2) })
    end

    it "a computed key still degrades the whole literal to Hash[K, V]" do
      type = scope.type_of(parse_expression("{ [1].size => 1, a: 2 }"))
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Hash")
    end

    it "a splatted entry still degrades the whole literal to Hash[K, V]" do
      type = scope.type_of(parse_expression("{ a: 1, **{ b: 2 } }"))
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Hash")
    end

    it "Hash#fetch returns the precise value for a static key (Slice 5 phase 2)" do
      type = scope.type_of(parse_expression("{ a: 1, b: 2 }.fetch(:a)"))
      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "Array#first(n) returns Array carrying the same Elem (end-to-end), on a non-Tuple receiver" do
      # As above: only a genuine `Nominal[Array]` receiver exercises the RBS overload path — a literal
      # `Tuple` carrier now folds `first(n)` to a precise sub-Tuple instead (#121; see the dedicated
      # example earlier in this describe block).
      union_elem = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2),
        Rigor::Type::Combinator.constant_of(3)
      )
      array_union = Rigor::Type::Combinator.nominal_of(Array, type_args: [union_elem])
      bound = scope.with_local(:xs, array_union)
      type = bound.type_of(parse_expression("xs.first(2)", scopes: [[:xs]]))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
      expect(type.type_args.size).to eq(1)
      element = type.type_args.first
      expect(element).to be_a(Rigor::Type::Union)
      expect(element.members.map(&:value)).to contain_exactly(1, 2, 3)
    end

    it "falls back to the first overload when no overload accepts the args" do
      # Integer#+ has overloads for Integer/Float/Rational/Complex. Symbol matches none, so the selector falls back to
      # the first overload (Integer) and returns Nominal[Integer].
      union_recv = Rigor::Type::Combinator.nominal_of(Integer)
      sym_arg = Rigor::Type::Combinator.constant_of(:foo)

      result = Rigor::Inference::MethodDispatcher.dispatch(
        receiver_type: union_recv,
        method_name: :+,
        arg_types: [sym_arg],
        environment: scope.environment
      )

      expect(result).to be_a(Rigor::Type::Nominal)
      expect(result.class_name).to eq("Integer")
    end
  end

  describe "containers and definitions (Slice 2 strengthening)" do
    it "types HashNode with static symbol keys as HashShape (Slice 5 phase 1)" do
      type = scope.type_of(parse_expression("{ a: 1, b: 2 }"))

      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs.keys).to eq(%i[a b])
    end

    it "types empty HashNode as the empty HashShape{} carrier (v0.0.7)" do
      # `{}` resolves to `HashShape{}` (closed, no pairs) so HashShape projections (`empty?`, `count`, `first`, `keys`,
      # `values`) fold against it. Both carriers erase to plain `Hash` for RBS interop.
      type = scope.type_of(parse_expression("{}"))

      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs).to eq({})
    end

    it "types InterpolatedStringNode as Nominal[String]" do
      type = scope.type_of(parse_expression("\"foo \#{42}\""))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("String")
    end

    it "types InterpolatedSymbolNode as Nominal[Symbol]" do
      type = scope.type_of(parse_expression(":\"foo\#{42}\""))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Symbol")
    end

    it "types DefNode as Constant<Symbol> of the method name" do
      type = scope.type_of(parse_expression("def my_method; end"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(:my_method)
    end

    it "propagates ClassNode body to the last expression's type" do
      type = scope.type_of(parse_expression("class Foo; 42; end"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(42)
    end

    it "types an empty class as Constant<nil>" do
      type = scope.type_of(parse_expression("class Foo; end"))

      expect(type.value).to be_nil
    end

    it "propagates ModuleNode body to the last expression's type" do
      type = scope.type_of(parse_expression("module Foo; :ok; end"))

      expect(type.value).to eq(:ok)
    end

    it "types AliasMethodNode/UndefNode as Constant<nil>" do
      alias_type = scope.type_of(parse_expression("alias new_name old_name"))
      undef_type = scope.type_of(parse_expression("undef foo"))

      expect(alias_type.value).to be_nil
      expect(undef_type.value).to be_nil
    end
  end

  describe "variables and self (Slice 2 strengthening)" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "silently types SelfNode as Dynamic[Top] when scope has no self_type" do
      type = scope.type_of(parse_expression("self"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "types SelfNode as the scope's self_type when one is set (Slice A-engine)" do
      foo = Rigor::Type::Combinator.nominal_of("Foo")
      bound = scope.with_self_type(foo)
      type = bound.type_of(parse_expression("self"), tracer: tracer)
      expect(type).to eq(foo)
      expect(tracer).to be_empty
    end

    it "silently types InstanceVariableReadNode as Dynamic[Top]" do
      type = scope.type_of(parse_expression("@x"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "types InstanceVariableWriteNode as the rvalue type" do
      type = scope.type_of(parse_expression("@x = 7"), tracer: tracer)

      expect(type.value).to eq(7)
      expect(tracer).to be_empty
    end

    it "silently types ClassVariableReadNode as Dynamic[Top]" do
      type = scope.type_of(parse_expression("@@x"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "types InstanceVariableOrWriteNode as the rvalue type" do
      type = scope.type_of(parse_expression("@x ||= 7"), tracer: tracer)

      expect(type.value).to eq(7)
      expect(tracer).to be_empty
    end

    describe "ivar/cvar/global reads consult Scope bindings (Slice 7 phase 1)" do
      it "returns the bound type for an InstanceVariableReadNode" do
        bound = scope.with_ivar(:@x, Rigor::Type::Combinator.constant_of(7))
        type = bound.type_of(parse_expression("@x"))
        expect(type).to eq(Rigor::Type::Combinator.constant_of(7))
      end

      it "returns the bound type for a ClassVariableReadNode" do
        bound = scope.with_cvar(:@@k, Rigor::Type::Combinator.constant_of("v"))
        type = bound.type_of(parse_expression("@@k"))
        expect(type).to eq(Rigor::Type::Combinator.constant_of("v"))
      end

      it "returns the bound type for a GlobalVariableReadNode" do
        bound = scope.with_global(:$g, Rigor::Type::Combinator.constant_of(42))
        type = bound.type_of(parse_expression("$g"))
        expect(type).to eq(Rigor::Type::Combinator.constant_of(42))
      end

      it "falls through to Dynamic[Top] (without a fallback event) when no binding exists" do
        type = scope.type_of(parse_expression("@unbound"), tracer: tracer)
        expect(type).to equal(Rigor::Type::Combinator.untyped)
        expect(tracer).to be_empty
      end
    end
  end

  describe "parameter and block positions (Slice 2 strengthening)" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "silently types ParametersNode and its parameter children as Dynamic[Top]" do
      def_node = parse_expression("def foo(a, b: 1, *c, **d, &e); end")
      params = def_node.parameters

      expect(scope.type_of(params, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      params.requireds.each do |param|
        expect(scope.type_of(param, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      end
      expect(tracer).to be_empty
    end

    it "silently types BlockNode/BlockParametersNode/BlockArgumentNode as Dynamic[Top]" do
      call_node = parse_expression("foo(&blk) { |x| x }")
      block_node = call_node.block

      expect(scope.type_of(block_node, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      expect(scope.type_of(block_node.parameters, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end
  end

  describe "`&:symbol` block-pass dispatcher recognition (ADR-14 gap #3 d)" do
    let(:project_scope) { Rigor::Scope.empty(environment: Rigor::Environment.for_project) }

    it "selects the block-bearing overload of Hash#transform_values for &:freeze" do
      type = project_scope.type_of(parse_expression('{ a: "x" }.transform_values(&:freeze)'))

      # Without the gap-(d) fix, this resolves to `Enumerator[...]` via the no-block overload. With the per-pair
      # HashShape fold (added alongside ADR-14 gap-(d)), the result is a precise `HashShape` rather than the widened
      # `Hash` — both confirm the block-bearing overload was selected.
      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs.keys).to eq([:a])
    end

    it "per-pair folds Hash#transform_keys into a HashShape when the block yields a constant key" do
      type = project_scope.type_of(parse_expression("{ a: 1 }.transform_keys { |k| k.to_s }"))

      expect(type).to be_a(Rigor::Type::HashShape)
      expect(type.pairs.keys).to eq(["a"])
      expect(type.pairs.values.map(&:value)).to eq([1])
    end

    it "declines Hash#transform_keys (falls back to the nominal Hash carrier) for a non-constant new key" do
      type = project_scope.type_of(parse_expression("{ a: 1 }.transform_keys { |k| rand }"))

      expect(type.class_name).to eq("Hash")
    end

    it "per-element folds Array#map for &:to_s into a Tuple" do
      type = project_scope.type_of(parse_expression("[1, 2, 3].map(&:to_s)"))

      # The per-element block fold now recognises the `&:symbol` shorthand: the symbol is dispatched as a zero-arg
      # method on each Tuple element, so `[1, 2, 3].map(&:to_s)` folds to `Tuple[Constant["1"], Constant["2"],
      # Constant["3"]]` — strictly tighter than the RBS-projected `Array[String]`.
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements.map(&:value)).to eq(%w[1 2 3])
    end
  end

  describe "control flow (Slice 3 phase 1)" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "types IfNode as the union of its then-branch and else-branch" do
      type = scope.type_of(parse_expression("if cond; 1; else; 2; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "includes Constant<nil> in the IfNode union when there is no else branch" do
      type = scope.type_of(parse_expression("if cond; 1; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(nil)
      )

      expect(type).to eq(expected)
    end

    it "unions through elsif chains" do
      type = scope.type_of(parse_expression("if a; 1; elsif b; 2; else; 3; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2),
        Rigor::Type::Combinator.constant_of(3)
      )

      expect(type).to eq(expected)
    end

    it "types UnlessNode using its else_clause field" do
      type = scope.type_of(parse_expression("unless cond; 1; else; 2; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "short-circuits AndNode on a Constant-truthy left to the right operand (v0.0.6)" do
      # `1 && 2` — `1` is truthy, so the value of the expression is `2`.
      type = scope.type_of(parse_expression("1 && 2"))
      expect(type).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "short-circuits OrNode on a Constant-truthy left to the left operand (v0.0.6)" do
      # `1 || 2` — `1` is truthy, so `||` returns `1`.
      type = scope.type_of(parse_expression("1 || 2"))
      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still unions both operands when the AndNode left is non-Constant" do
      type = scope.type_of(parse_expression("x && 2"))
      expect(type).to be_a(Rigor::Type::Union)
    end

    it "strips the left operand's nil on the OrNode short-circuit edge" do
      # `s || 7` yields `s` only when `s` is truthy, so a `String?` left
      # can never contribute `nil` to the value of the `||` — the falsey
      # constituent hands off to the right operand. Mirrors the scope-side
      # `StatementEvaluator#eval_and_or`; before this fix `type_of_and_or`
      # unioned the raw (un-narrowed) left type, re-admitting the stripped
      # `nil` and leaking it back into the enclosing method's return type.
      nullable_string = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("String"),
        Rigor::Type::Combinator.constant_of(nil)
      )
      bound = scope.with_local(:s, nullable_string)
      type = bound.type_of(parse_expression("s || 7", scopes: [[:s]]))

      expect(type).to eq(
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.nominal_of("String"),
          Rigor::Type::Combinator.constant_of(7)
        )
      )
    end

    it "strips the left operand's truthy constituents on the AndNode short-circuit edge" do
      # `s && 7` yields `s` only when `s` is falsey, so a `String?` left contributes only its `nil` (the `String` part
      # hands off to `7`).
      nullable_string = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("String"),
        Rigor::Type::Combinator.constant_of(nil)
      )
      bound = scope.with_local(:s, nullable_string)
      type = bound.type_of(parse_expression("s && 7", scopes: [[:s]]))

      expect(type).to eq(
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.constant_of(nil),
          Rigor::Type::Combinator.constant_of(7)
        )
      )
    end

    it "types CaseNode as the union of every when body and the else clause" do
      source = "case x; when 1; :a; when 2; :b; else; :c; end"
      type = scope.type_of(parse_expression(source))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(:a),
        Rigor::Type::Combinator.constant_of(:b),
        Rigor::Type::Combinator.constant_of(:c)
      )

      expect(type).to eq(expected)
    end

    it "stops at the first definitely-matching `when` (Constant subject, Class pattern)" do
      type = scope.type_of(parse_expression("case 1; when Integer; :int; when String; :str; else; :other; end"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(:int))
    end

    it "unions prior `:maybe` branches with the first definitely-matching `when`" do
      # rand(10) -> Integer (always-yes against `Integer`). Prior `when 0` is `:maybe` (Integer might be 0), so the
      # result includes both bodies but stops before reaching the else.
      type = scope.type_of(parse_expression("case rand(10); when 0; :zero; when Integer; :int; else; :other; end"))

      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(:zero),
        Rigor::Type::Combinator.constant_of(:int)
      )
      expect(type).to eq(expected)
    end

    it "drops a definitely-no `when` and selects the next definitely-yes branch" do
      type = scope.type_of(parse_expression("case :a; when :z; 1; when :a; 2; when :b; 3; end"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "falls through to the else clause when every `when` is definitely-no" do
      type = scope.type_of(parse_expression("case :z; when :a; 1; when :b; 2; else; :fallback; end"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(:fallback))
    end

    it "treats a multi-condition `when a, b` as `:yes` when any condition is `:yes`" do
      type = scope.type_of(parse_expression("case 5; when 1, 2; :low; when 5, 10; :mid; else; :other; end"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(:mid))
    end

    it "types BeginNode/RescueNode as the union of the body and rescue chain" do
      source = "begin; 1; rescue ArgumentError; 2; rescue; 3; end"
      type = scope.type_of(parse_expression(source))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2),
        Rigor::Type::Combinator.constant_of(3)
      )

      expect(type).to eq(expected)
    end

    it "uses the else clause as the begin's primary value when no exception fires" do
      source = "begin; 1; rescue; 2; else; :ok; end"
      type = scope.type_of(parse_expression(source))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(:ok),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "types `expr rescue fallback` as the union of both expressions" do
      type = scope.type_of(parse_expression("foo rescue 42"))

      expect(type.describe).to include("42")
    end

    it "types ReturnNode/BreakNode/NextNode/RetryNode as Bot" do
      bot = Rigor::Type::Combinator.bot

      expect(scope.type_of(parse_expression("return 1"))).to equal(bot)
      expect(scope.type_of(parse_expression("loop { break 1 }").block.body.body.first)).to equal(bot)
      expect(scope.type_of(parse_expression("loop { next 1 }").block.body.body.first)).to equal(bot)
    end

    it "collapses Bot under union (return inside an if branch is absorbed)" do
      type = scope.type_of(parse_expression("if cond; return; else; 7; end"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(7))
    end

    it "types YieldNode as Dynamic[Top]" do
      def_node = parse_expression("def foo; yield(1); end")
      yield_node = def_node.body.body.first

      expect(scope.type_of(yield_node, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "types WhileNode and UntilNode as Constant<nil>" do
      while_type = scope.type_of(parse_expression("while cond; 1; end"))
      until_type = scope.type_of(parse_expression("until cond; 1; end"))

      expect(while_type.value).to be_nil
      expect(until_type.value).to be_nil
    end

    it "types LambdaNode as Nominal[Proc]" do
      type = scope.type_of(parse_expression("-> { 42 }"))

      expect(type.class_name).to eq("Proc")
    end

    it "types static integer RangeNode as Constant[Range]" do
      type = scope.type_of(parse_expression("(1..10)"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1..10))
    end

    it "keeps dynamic RangeNode as Nominal[Range]" do
      type = scope.type_of(parse_expression("(start..10)"))

      expect(type.class_name).to eq("Range")
    end

    it "types static string RangeNode as Constant<Range>" do
      type = scope.type_of(parse_expression('("a".."z")'))

      expect(type).to eq(Rigor::Type::Combinator.constant_of("a".."z"))
    end

    it "types static Float RangeNode as Constant<Range>" do
      type = scope.type_of(parse_expression("(1.5..2.5)"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1.5..2.5))
    end

    it "types exclusive static integer RangeNode as Constant<Range>" do
      type = scope.type_of(parse_expression("(1...5)"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1...5))
    end

    it "folds a RangeNode whose bounds TYPE as Constant into Constant<Range>" do
      # `n` is pinned to a constant by an enclosing binding; the bound is a LocalVariableReadNode, not a literal
      # IntegerNode, so the fold has to consult the evaluated bound type (fact2 chain).
      type = scope.with_local(:n, Rigor::Type::Combinator.constant_of(5))
                  .type_of(parse_expression("(1..n)", scopes: [[:n]]))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1..5))
    end

    it "keeps a RangeNode with a non-constant bound as Range[T]" do
      type = scope.with_local(:m, Rigor::Type::Combinator.nominal_of("Integer"))
                  .type_of(parse_expression("(1..m)", scopes: [[:m]]))

      expect(type.class_name).to eq("Range")
      expect(type.type_args.first).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "falls back to a bare Range with no type_args when neither endpoint contributes a typable shape" do
      type = scope.with_local(:a, Rigor::Type::Combinator.untyped)
                  .with_local(:b, Rigor::Type::Combinator.untyped)
                  .type_of(parse_expression("(a..b)", scopes: [%i[a b]]))

      expect(type.class_name).to eq("Range")
      expect(type.type_args).to be_empty
    end

    it "derives the Integer element type from a Type::IntegerRange-typed endpoint" do
      type = scope.with_local(:n, Rigor::Type::Combinator.integer_range(1, 10))
                  .type_of(parse_expression("(n..20)", scopes: [[:n]]))

      expect(type.class_name).to eq("Range")
      expect(type.type_args.first).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "types non-interpolated RegularExpressionNode as Constant<Regexp> (v0.0.7)" do
      type = scope.type_of(parse_expression("/foo/"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(/foo/))
    end

    it "preserves Regexp options on the lifted Constant (v0.0.7)" do
      type = scope.type_of(parse_expression("/Foo/i"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(/Foo/i))
    end
  end

  describe "branch elision for expression-position conditionals (v0.0.6)" do
    it "elides the else branch of a ternary on a Constant-truthy predicate" do
      type = scope.type_of(parse_expression('true ? "yes" : nil'))
      expect(type).to eq(Rigor::Type::Combinator.constant_of("yes"))
    end

    it "elides the then branch of a ternary on a Constant-falsey predicate" do
      type = scope.type_of(parse_expression('false ? "yes" : "no"'))
      expect(type).to eq(Rigor::Type::Combinator.constant_of("no"))
    end

    it "elides through a constant-fold predicate (1.even? -> Constant[false])" do
      type = scope.type_of(parse_expression('1.even? ? "even" : "odd"'))
      expect(type).to eq(Rigor::Type::Combinator.constant_of("odd"))
    end

    it "elides the unreachable branch of `unless` on a Constant predicate" do
      type = scope.type_of(parse_expression('"x" unless true'))
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    it "still unions both branches when the predicate is non-Constant" do
      # `x` is unbound so its type is `Dynamic[Top]`; both branches remain live and the result is the union.
      type = scope.type_of(parse_expression('x ? "yes" : "no"'))
      members = type.members.map(&:value)
      expect(members).to contain_exactly("yes", "no")
    end
  end

  describe "literal-string flow tracking on interpolation (v0.0.9 F)" do
    let(:literal_string) { Rigor::Type::Combinator.literal_string }

    it "lifts a fully literal-bearing interpolation to literal-string" do
      bound = scope.with_local(:name, Rigor::Type::Combinator.constant_of("Alice"))
      node = parse_expression("\"hello \#{name}!\"", scopes: [[:name]])
      expect(bound.type_of(node)).to eq(literal_string)
    end

    it "lifts an interpolation whose embedded type is itself literal-string" do
      bound = scope.with_local(:greeting, literal_string)
      node = parse_expression("\"prefix-\#{greeting}-suffix\"", scopes: [[:greeting]])
      expect(bound.type_of(node)).to eq(literal_string)
    end

    it "lifts when the embedded part is non-empty-literal-string (literal-bearing intersection)" do
      nels = Rigor::Type::Combinator.non_empty_literal_string
      bound = scope.with_local(:greeting, nels)
      node = parse_expression("\"hi \#{greeting}!\"", scopes: [[:greeting]])
      expect(bound.type_of(node)).to eq(literal_string)
    end

    it "widens to plain Nominal[String] when any embedded part is non-literal" do
      bound = scope.with_local(:user, Rigor::Type::Combinator.nominal_of("String"))
      node = parse_expression("\"hello \#{user}!\"", scopes: [[:user]])
      type = bound.type_of(node)
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("String")
    end

    it "widens when an embedded part is a non-String value" do
      bound = scope.with_local(:n, Rigor::Type::Combinator.constant_of(42))
      node = parse_expression("\"\#{n}\"", scopes: [[:n]])
      type = bound.type_of(node)
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("String")
    end

    it "lifts when every member of a Union embedded type is literal-bearing" do
      union = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of("a"),
        Rigor::Type::Combinator.constant_of("b")
      )
      bound = scope.with_local(:tag, union)
      node = parse_expression("\"<\#{tag}>\"", scopes: [[:tag]])
      expect(bound.type_of(node)).to eq(literal_string)
    end
  end

  describe "per-element block fold over Constant<Range> receivers (v0.0.6 phase 2)" do
    it "folds `.map` over a small inclusive Constant<Range> to a per-position Tuple" do
      type = scope.type_of(parse_expression("(1..3).map { |i| i * 2 }"))
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements.map(&:value)).to eq([2, 4, 6])
    end

    it "folds `.select` over a small exclusive Constant<Range>, dropping non-matching positions" do
      type = scope.type_of(parse_expression("(1...4).select { |i| i.odd? }"))
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements.map(&:value)).to eq([1, 3])
    end

    it "declines (falls back to the nominal Array carrier) above the per-element range cap" do
      type = scope.type_of(parse_expression("(1..20).map { |i| i * 2 }"))
      expect(type.class_name).to eq("Array")
    end
  end

  # Issue #533 — a refinement (`Refined`) or subtraction (`Difference` — `non-empty-string` is
  # `String − \"\"`) erases to its base for RBS method lookup, so a method the catalog tier does not
  # promote still resolves instead of declining the whole dispatch to Dynamic.
  describe "refined-receiver RBS lookup erasure" do
    let(:project_scope) { Rigor::Scope.empty(environment: Rigor::Environment.for_project) }

    it "resolves comparison and plain methods on the predefined-constant refinements" do
      expect(project_scope.type_of(parse_expression('RUBY_VERSION != "1.0"')).describe(:short)).to eq("bool")
      expect(project_scope.type_of(parse_expression('RUBY_VERSION.split(".")')).describe(:short)).to eq("Array[String]")
    end

    it "keeps the catalog tier's refinement promotions winning (control)" do
      expect(project_scope.type_of(parse_expression("RUBY_VERSION.upcase")).describe(:short)).to eq("non-empty-string")
    end
  end
end
