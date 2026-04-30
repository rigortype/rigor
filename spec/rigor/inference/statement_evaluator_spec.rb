# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::StatementEvaluator do
  let(:scope) { Rigor::Scope.empty }

  def parse_program(source)
    Prism.parse(source).value
  end

  def evaluate(source, base_scope: scope)
    base_scope.evaluate(parse_program(source))
  end

  describe ".evaluate (Scope#evaluate delegate)" do
    it "returns a [type, scope] pair" do
      type, post = evaluate("1 + 2")
      expect(type).to be_a(Rigor::Type::Constant)
      expect(post).to be_a(Rigor::Scope)
    end

    it "leaves scope unchanged for pure expressions" do
      _, post = evaluate("1 + 2")
      expect(post).to eq(scope)
    end
  end

  describe "sequential statements" do
    it "binds local-variable writes into the post-scope" do
      _, post = evaluate("x = 1")
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "threads bindings across statements" do
      type, post = evaluate(<<~RUBY)
        x = 1
        y = x + 2
        y
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(3))
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:y)).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "produces Constant[nil] for an empty program" do
      type, post = evaluate("")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
      expect(post).to eq(scope)
    end

    it "discards intermediate types but preserves their scope effects" do
      _, post = evaluate(<<~RUBY)
        x = 1
        :ignore_this
        y = x
      RUBY
      expect(post.local(:y)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "does not mutate the receiver scope" do
      bound = scope.with_local(:seed, Rigor::Type::Combinator.constant_of(7))
      _, _post = bound.evaluate(parse_program("x = 1"))
      expect(bound.local(:seed)).to eq(Rigor::Type::Combinator.constant_of(7))
      expect(bound.local(:x)).to be_nil
    end
  end

  describe "if/unless branching" do
    it "unions branch types and binds names defined in both branches" do
      type, post = evaluate(<<~RUBY)
        if cond
          x = 1
        else
          x = 2
        end
        x
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, 2)
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2)
    end

    it "nil-injects names bound in only one branch (then-only)" do
      _, post = evaluate(<<~RUBY)
        if cond
          x = 1
        end
      RUBY
      expect(post.local(:x)).to be_a(Rigor::Type::Union)
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, nil)
    end

    it "nil-injects names bound in only one branch (else-only)" do
      _, post = evaluate(<<~RUBY)
        unless cond
          x = 1
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, nil)
    end

    it "nil-injects on each side independently when branches bind disjoint names" do
      _, post = evaluate(<<~RUBY)
        if cond
          x = 1
        else
          y = 2
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, nil)
      expect(post.local(:y).members.map(&:value)).to contain_exactly(2, nil)
    end

    it "handles elsif chains as nested IfNodes" do
      type, _post = evaluate(<<~RUBY)
        if cond1
          1
        elsif cond2
          2
        else
          3
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, 2, 3)
    end
  end

  describe "case/when branching" do
    it "unions every when-clause type and the else-clause type" do
      type, _post = evaluate(<<~RUBY)
        case kind
        when 1 then "a"
        when 2 then "b"
        else        "c"
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly("a", "b", "c")
    end

    it "nil-injects names bound in some but not all branches" do
      _, post = evaluate(<<~RUBY)
        case kind
        when 1 then x = 1
        when 2 then x = 2; y = 9
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2, nil)
      expect(post.local(:y).members.map(&:value)).to contain_exactly(9, nil)
    end
  end

  describe "begin/rescue/ensure" do
    it "joins the body and rescue-chain scopes" do
      _, post = evaluate(<<~RUBY)
        begin
          x = 1
        rescue
          x = 2
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2)
    end

    it "propagates the ensure-clause's scope effects to the post-scope" do
      _, post = evaluate(<<~RUBY)
        begin
          x = 1
        ensure
          y = 2
        end
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:y)).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "uses the else-clause's value when present" do
      type, _post = evaluate(<<~RUBY)
        begin
          1
        rescue
          2
        else
          3
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(2, 3)
    end
  end

  describe "loops" do
    it "types as Constant[nil] and nil-injects loop-bound names" do
      type, post = evaluate(<<~RUBY)
        x = 0
        while cond
          x = 1
        end
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
      expect(post.local(:x).members.map(&:value)).to contain_exactly(0, 1)
    end

    it "until-loop nil-injects body-bound names" do
      _, post = evaluate(<<~RUBY)
        until cond
          y = "hi"
        end
      RUBY
      expect(post.local(:y).members.map(&:value)).to contain_exactly("hi", nil)
    end
  end

  describe "and/or short-circuit" do
    it "joins post-scopes of both operands with nil-injection" do
      _, post = evaluate(<<~RUBY)
        (x = 1) && (y = 2)
      RUBY
      # `x = 1` always runs, so x is preserved straight through.
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      # `y = 2` runs only when LHS is truthy, so y is nil-injected.
      expect(post.local(:y).members.map(&:value)).to contain_exactly(2, nil)
    end

    it "unions the two operand types" do
      type, _post = evaluate("1 || \"hi\"")
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, "hi")
    end
  end

  describe "parentheses thread scope through their body" do
    it "binds locals declared inside the parentheses" do
      _, post = evaluate("(x = 1; x + 1)")
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "fall-through to ExpressionTyper" do
    it "leaves scope unchanged for unrecognised statement-y nodes" do
      _, post = evaluate("[1, 2, 3].first")
      expect(post).to eq(scope)
    end

    it "does not record fallback events for recognised statement-y nodes" do
      tracer = Rigor::Inference::FallbackTracer.new
      scope.evaluate(parse_program("x = 1"), tracer: tracer)
      expect(tracer).to be_empty
    end

    it "carries the tracer into ExpressionTyper for inner expressions" do
      tracer = Rigor::Inference::FallbackTracer.new
      scope.evaluate(parse_program("foo()"), tracer: tracer)
      expect(tracer).not_to be_empty
    end
  end

  describe "on_enter callback" do
    it "fires once per visited node with the entry scope" do
      events = []
      on_enter = ->(node, scope) { events << [node.class, scope.locals.keys.sort] }
      ast = parse_program(<<~RUBY)
        x = 1
        y = x + 2
      RUBY
      described_class.new(scope: scope, on_enter: on_enter).evaluate(ast)

      # Sanity: every recursive sub_eval threads the callback so the
      # rvalue (`x + 2`) is recorded with `x` already bound.
      x_plus_2_event = events.find { |klass, _| klass == Prism::CallNode }
      expect(x_plus_2_event).not_to be_nil
      expect(x_plus_2_event[1]).to include(:x)
    end

    it "fires for nodes whose handler is the default fallback branch" do
      events = []
      on_enter = ->(node, _scope) { events << node.class }
      ast = parse_program("foo(1)")
      described_class.new(scope: scope, on_enter: on_enter).evaluate(ast)

      # The CallNode has no statement-evaluator handler; the default
      # branch still fires on_enter so callers (the ScopeIndexer) can
      # record its entry scope.
      expect(events).to include(Prism::CallNode)
    end

    it "is optional and does not affect the result when omitted" do
      ast = parse_program("x = 1")
      _, post = described_class.new(scope: scope).evaluate(ast)
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "DefNode / ClassNode handlers (Slice 3 phase 2 follow-up)" do
    let(:default_env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

    # Build an `on_enter` callback that records the entry-scope
    # binding for `name` whenever the evaluator visits a
    # LocalVariableReadNode for that name. Returns the events array
    # (mutable) and the callback together.
    def watch_local_reads(name)
      events = []
      on_enter = lambda do |node, s|
        next unless node.is_a?(Prism::LocalVariableReadNode) && node.name == name

        events << s.local(name)
      end
      [events, on_enter]
    end

    it "types a top-level def as Constant[:method_name] and leaves the outer scope unchanged" do
      type, post = evaluate("def add(a, b); a + b; end")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(:add))
      expect(post).to eq(scope)
    end

    it "binds parameters to Dynamic[Top] when no class context is present" do
      events, on_enter = watch_local_reads(:a)
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program("def foo(a); a; end"))
      expect(events.first).to equal(Rigor::Type::Combinator.untyped)
    end

    it "binds parameters from RBS when wrapped in a class with a known method" do
      events, on_enter = watch_local_reads(:other)
      described_class.new(scope: default_env_scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Integer
          def divmod(other); other; end
        end
      RUBY
      expect(events.first).to be_a(Rigor::Type::Union)
      expect(events.first.members.map(&:class_name)).to include("Integer", "Float")
    end

    it "routes def self.foo through singleton-method RBS lookup" do
      events, on_enter = watch_local_reads(:n)
      described_class.new(scope: default_env_scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Integer
          def self.sqrt(n); n; end
        end
      RUBY
      # The singleton path was consulted (no exception, the local is
      # bound to *some* type, possibly Dynamic[Top] when the RBS type
      # is an interface alias). The structural property under test is
      # that the local was bound at all.
      expect(events).not_to be_empty
      expect(events.first).not_to be_nil
    end

    it "uses singleton lookup inside class << self blocks" do
      events, on_enter = watch_local_reads(:n)
      described_class.new(scope: default_env_scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Integer
          class << self
            def sqrt(n); n; end
          end
        end
      RUBY
      expect(events).not_to be_empty
      expect(events.first).not_to be_nil
    end

    it "discards the class body's locals from the outer scope" do
      _type, post = evaluate("class Foo; x = 1; end")
      expect(post.local(:x)).to be_nil
    end

    it "evaluates a class body in a fresh scope (outer locals are not visible)" do
      ast = parse_program(<<~RUBY)
        x = 1
        class Foo
          x
        end
      RUBY
      class_body_scopes = []
      on_enter = ->(_node, s) { class_body_scopes << s.locals.keys.sort }
      described_class.new(scope: scope, on_enter: on_enter).evaluate(ast)
      # The class body's children enter with the fresh empty scope
      # (`[]`), even though the outer `x = 1` post-scope contains x.
      expect(class_body_scopes).to include([])
    end

    it "injects Singleton[Foo] as self_type inside `class Foo` body (Slice A-engine)" do
      observed = []
      on_enter = ->(node, s) { observed << s.self_type if node.is_a?(Prism::SelfNode) }
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Foo
          self
        end
      RUBY
      expect(observed.first).to eq(Rigor::Type::Combinator.singleton_of("Foo"))
    end

    it "injects Nominal[Foo] as self_type inside an instance method body" do
      observed = []
      on_enter = ->(node, s) { observed << s.self_type if node.is_a?(Prism::SelfNode) }
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Foo
          def bar; self; end
        end
      RUBY
      expect(observed).to include(Rigor::Type::Combinator.nominal_of("Foo"))
    end

    it "injects Singleton[Foo] inside a `def self.bar` body" do
      observed = []
      on_enter = lambda do |node, s|
        next unless node.is_a?(Prism::SelfNode) && s.self_type.is_a?(Rigor::Type::Singleton)

        observed << s.self_type
      end
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Foo
          def self.bar; self; end
        end
      RUBY
      expect(observed.last).to eq(Rigor::Type::Combinator.singleton_of("Foo"))
    end

    it "injects Singleton[Foo] inside `class << self` def bodies" do
      observed = []
      on_enter = ->(node, s) { observed << [node.class, s.self_type] if node.is_a?(Prism::SelfNode) }
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Foo
          class << self
            def bar; self; end
          end
        end
      RUBY
      # The body of `bar` sees self as Singleton[Foo].
      types = observed.map(&:last)
      expect(types).to include(Rigor::Type::Combinator.singleton_of("Foo"))
    end

    it "leaves self_type nil for top-level defs" do
      observed = []
      on_enter = ->(node, s) { observed << s.self_type if node.is_a?(Prism::SelfNode) }
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program("def bar; self; end"))
      expect(observed.first).to be_nil
    end

    it "qualifies nested class names with :: without raising" do
      # The binder's class_path is "A::B" here. Neither A nor A::B exist
      # in core RBS, so x falls back to Dynamic[Top]; the structural
      # test is just that no exception is raised.
      ast = parse_program("class A; class B; def foo(x); x; end; end; end")
      expect { described_class.new(scope: scope).evaluate(ast) }.not_to raise_error
    end

    it "renders the qualified name correctly for class A::B" do
      ast = parse_program("class A::B; def foo(x); x; end; end")
      expect { described_class.new(scope: scope).evaluate(ast) }.not_to raise_error
    end
  end

  describe "narrowing on if/unless (Slice 6 phase 1)" do
    let(:union_int_nil) do
      Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("Integer"),
        Rigor::Type::Combinator.constant_of(nil)
      )
    end

    # Parse `source` with `x` and `y` pre-declared as locals so the
    # parser produces `LocalVariableReadNode` rather than implicit
    # `CallNode` references. Tests that need a different local set
    # MAY pass `locals:`.
    def parse_with_locals(source, locals: %i[x y])
      Prism.parse(source, scopes: [locals]).value
    end

    # Build an `on_enter` callback that records the entry-scope
    # binding for `name` whenever the evaluator visits a
    # LocalVariableReadNode for that name. Returns the events array
    # (mutable) and the callback together.
    def watch_local_reads(name)
      events = []
      on_enter = lambda do |node, s|
        next unless node.is_a?(Prism::LocalVariableReadNode) && node.name == name

        events << s.local(name)
      end
      [events, on_enter]
    end

    it "narrows truthy/falsey edges of `if x` for a Union[T, nil] local" do
      bound = scope.with_local(:x, union_int_nil)
      events, on_enter = watch_local_reads(:x)
      ast = parse_with_locals(<<~RUBY)
        if x
          x
        else
          x
        end
      RUBY
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)

      # Predicate read sees the untouched union; the then-branch
      # read sees x narrowed to Integer; the else-branch read sees
      # x narrowed to Constant[nil].
      expect(events[0]).to eq(union_int_nil)
      expect(events[1]).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(events[2]).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    it "narrows on `if x.nil?`" do
      bound = scope.with_local(:x, union_int_nil)
      events, on_enter = watch_local_reads(:x)
      ast = parse_with_locals(<<~RUBY)
        if x.nil?
          x
        else
          x
        end
      RUBY
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)

      then_read, else_read = events.last(2)
      expect(then_read).to eq(Rigor::Type::Combinator.constant_of(nil))
      expect(else_read).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "narrows on `unless x` by swapping truthy/falsey edges" do
      bound = scope.with_local(:x, union_int_nil)
      events, on_enter = watch_local_reads(:x)
      ast = parse_with_locals(<<~RUBY)
        unless x
          x
        else
          x
        end
      RUBY
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)

      # In `unless x` the body runs when x is falsey, the else-clause
      # when x is truthy. The narrower swaps the two edges accordingly.
      then_read, else_read = events.last(2)
      expect(then_read).to eq(Rigor::Type::Combinator.constant_of(nil))
      expect(else_read).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "narrows the value of a then-branch (Union -> non-nil fragment)" do
      bound = scope.with_local(:x, union_int_nil)
      type, _post = bound.evaluate(parse_with_locals(<<~RUBY))
        if x.nil?
          0
        else
          x
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to include(
        Rigor::Type::Combinator.constant_of(0),
        Rigor::Type::Combinator.nominal_of("Integer")
      )
    end

    it "joins narrowed scopes across branches with the original union" do
      bound = scope.with_local(:x, union_int_nil)
      _, post = bound.evaluate(parse_with_locals(<<~RUBY))
        if x
          x
        else
          x
        end
      RUBY
      # After the if, x has the union of the two narrowed branches,
      # which collapses back to the original `Integer | nil` because
      # the two narrowings partition the union.
      expect(post.local(:x)).to eq(union_int_nil)
    end

    it "evaluates the RHS of `&&` under the LHS truthy scope" do
      # `x.succ` only resolves cleanly when `x` is narrowed to a
      # non-nil Integer; otherwise dispatch over `Integer | nil`
      # cannot prove `NilClass` defines `succ`. The RHS therefore
      # types as `Nominal[Integer]` only when the narrower flowed
      # `x` into the RHS scope.
      bound = scope.with_local(:x, union_int_nil)
      type, _post = bound.evaluate(parse_with_locals("x && x.succ"))

      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to include(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "uses only the LHS falsey fragment in the value type of `&&`" do
      bound = scope.with_local(:x, union_int_nil)
      type, _post = bound.evaluate(parse_with_locals("x && 1"))

      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to contain_exactly(
        Rigor::Type::Combinator.constant_of(nil),
        Rigor::Type::Combinator.constant_of(1)
      )
    end

    it "evaluates the RHS of `||` under the LHS falsey scope" do
      # `x || x.nil?` reads `x` on the RHS only when the LHS is
      # falsey, i.e. when `x` is `nil`. Slice 6 phase 1 narrows
      # that read; the resulting `x.nil?` therefore folds to a
      # constant true.
      bound = scope.with_local(:x, union_int_nil)
      events, on_enter = watch_local_reads(:x)
      ast = parse_with_locals("x || x.nil?")
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)

      # The LHS read sees the unnarrowed union; we don't assert on
      # `events[1]` because the RHS receiver is typed via
      # ExpressionTyper, which does not fire `on_enter`. The
      # behavioural proof is in the dispatched return type below.
      expect(events.first).to eq(union_int_nil)

      type, _post = bound.evaluate(ast)
      expect(type).to be_a(Rigor::Type::Union)
      # The RHS `x.nil?` resolves on `Constant[nil]` to
      # `Constant[true]` because `x` was narrowed to `nil` in the
      # falsey branch. The full expression unions LHS and RHS.
      expect(type.members).to include(Rigor::Type::Combinator.constant_of(true))
    end

    it "uses only the LHS truthy fragment in the value type of `||`" do
      bound = scope.with_local(:x, union_int_nil)
      type, _post = bound.evaluate(parse_with_locals("x || 1"))

      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to contain_exactly(
        Rigor::Type::Combinator.nominal_of("Integer"),
        Rigor::Type::Combinator.constant_of(1)
      )
    end

    it "leaves locals untouched on if without a narrowable predicate" do
      bound = scope.with_local(:x, union_int_nil)
      events, on_enter = watch_local_reads(:x)
      ast = parse_with_locals(<<~RUBY)
        if foo
          x
        else
          x
        end
      RUBY
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)

      expect(events.last(2)).to all(eq(union_int_nil))
    end

    it "narrows compound `if a && b` predicates" do
      union_str_nil = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("String"),
        Rigor::Type::Combinator.constant_of(nil)
      )
      bound = scope
              .with_local(:x, union_int_nil)
              .with_local(:y, union_str_nil)
      type, _post = bound.evaluate(parse_with_locals("if x && y; x; else; 0; end"))

      # In the truthy branch x is narrowed to its non-falsey
      # fragment; the read of `x` therefore returns `Integer`.
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to include(
        Rigor::Type::Combinator.nominal_of("Integer"),
        Rigor::Type::Combinator.constant_of(0)
      )
    end

    it "threads equality narrowing across `&&` predicates" do
      literal_a = Rigor::Type::Combinator.constant_of("a")
      literal_b = Rigor::Type::Combinator.constant_of("b")
      union = Rigor::Type::Combinator.union(literal_a, literal_b)
      bound = scope.with_local(:x, union)
      type, _post = bound.evaluate(parse_with_locals('if x == "a" && x == "b"; x; else; 0; end'))

      # The truthy branch is unreachable because the RHS sees x
      # narrowed to "a", then intersects that with "b".
      expect(type).to eq(Rigor::Type::Combinator.constant_of(0))
    end

    it "narrows is_a?(C) on a Union[Integer, String] in the then branch" do
      union_int_str = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("Integer"),
        Rigor::Type::Combinator.nominal_of("String")
      )
      bound = scope.with_local(:x, union_int_str)
      ast = parse_with_locals("if x.is_a?(Integer); x; else; x; end")
      events, on_enter = watch_local_reads(:x)
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)
      # The predicate receiver is typed by ExpressionTyper directly
      # and is not surfaced through `on_enter`. Only the two
      # body-position reads of `x` are observed here.
      expect(events.size).to eq(2)
      then_read, else_read = events
      expect(then_read).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(else_read).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "narrows Numeric DOWN to Integer under is_a?(Integer)" do
      bound = scope.with_local(:x, Rigor::Type::Combinator.nominal_of("Numeric"))
      ast = parse_with_locals("if x.is_a?(Integer); x; else; x; end")
      events, on_enter = watch_local_reads(:x)
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)
      then_read, else_read = events
      expect(then_read).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      # The else edge cannot prove "Numeric is not an Integer", so it
      # stays conservative and preserves Nominal[Numeric].
      expect(else_read).to eq(Rigor::Type::Combinator.nominal_of("Numeric"))
    end

    it "treats `unless x.is_a?(Integer)` as a swap of the truthy/falsey edges" do
      union_int_str = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("Integer"),
        Rigor::Type::Combinator.nominal_of("String")
      )
      bound = scope.with_local(:x, union_int_str)
      ast = parse_with_locals("unless x.is_a?(Integer); x; else; x; end")
      events, on_enter = watch_local_reads(:x)
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)
      then_read, else_read = events
      expect(then_read).to eq(Rigor::Type::Combinator.nominal_of("String"))
      expect(else_read).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end
  end

  describe "multi-write destructuring (Slice 5 phase 2 sub-phase 2)" do
    it "binds two targets element-wise from a tuple-typed rvalue" do
      _, post = evaluate("a, b = [1, 2]")
      expect(post.local(:a)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:b)).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "fills extra targets with Constant[nil] when the tuple is shorter" do
      _, post = evaluate("a, b, c = [1, 2]")
      expect(post.local(:a)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:b)).to eq(Rigor::Type::Combinator.constant_of(2))
      expect(post.local(:c)).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    it "binds the rest target as a Tuple of middle elements" do
      _, post = evaluate("a, *r, c = [1, 2, 3, 4]")
      expect(post.local(:a)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:c)).to eq(Rigor::Type::Combinator.constant_of(4))
      expect(post.local(:r)).to eq(
        Rigor::Type::Combinator.tuple_of(
          Rigor::Type::Combinator.constant_of(2),
          Rigor::Type::Combinator.constant_of(3)
        )
      )
    end

    it "recurses into nested MultiTargetNodes" do
      _, post = evaluate("a, (b, c) = [1, [2, 3]]")
      expect(post.local(:a)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:b)).to eq(Rigor::Type::Combinator.constant_of(2))
      expect(post.local(:c)).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "evaluates rhs once and exposes its bindings to the destructuring" do
      _, post = evaluate(<<~RUBY)
        pair = [10, 20]
        a, b = pair
      RUBY
      # `pair` is Tuple[10, 20], so destructuring sees the precise members.
      expect(post.local(:a)).to eq(Rigor::Type::Combinator.constant_of(10))
      expect(post.local(:b)).to eq(Rigor::Type::Combinator.constant_of(20))
    end

    it "binds dynamic values when the rhs is not a tuple carrier" do
      _, post = evaluate("a, b = foo")
      dyn = Rigor::Type::Combinator.untyped
      expect(post.local(:a)).to eq(dyn)
      expect(post.local(:b)).to eq(dyn)
    end

    it "preserves the multi-write expression's value as the rhs type" do
      type, _post = evaluate("a, b = [1, 2]")
      expect(type).to eq(
        Rigor::Type::Combinator.tuple_of(
          Rigor::Type::Combinator.constant_of(1),
          Rigor::Type::Combinator.constant_of(2)
        )
      )
    end

    it "skips non-local destructuring targets" do
      _, post = evaluate("@x, b = [1, 2]")
      expect(post.local(:b)).to eq(Rigor::Type::Combinator.constant_of(2))
      expect(post.local(:@x)).to be_nil
    end
  end

  describe "block return type uplift (Slice 6 phase C sub-phase 2)" do
    it "infers Array[String] from `[1, 2, 3].map { |n| n.to_s }`" do
      type, _post = evaluate("[1, 2, 3].map { |n| n.to_s }")
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
      expect(type.type_args.size).to eq(1)
      expect(type.type_args.first).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "binds numbered-parameter receivers and threads the block return type" do
      type, _post = evaluate("[1, 2, 3].map { _1 + 1 }")
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
      # `_1 + 1` collapses to Integer once the dispatcher projects
      # the receiver union; the test asserts the projection survives
      # through `Array#map`'s `U` binding.
      expect(type.type_args.first).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "does not raise when the receiver is unknown and the block has named parameters" do
      type, _post = evaluate("foo.map { |n| n.to_s }")
      expect(type).to eq(Rigor::Type::Combinator.untyped)
    end
  end

  describe "downstream inference benefits" do
    it "lets methods on bound locals resolve through RBS" do
      type, _post = evaluate(<<~RUBY)
        x = 1
        x.succ
      RUBY
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "lets shape-typed locals resolve through dispatch" do
      # Slice 5 phase 2 picks the first element directly rather than
      # the projected union; the test asserts the precise answer.
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs.first
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "propagates HashShape locals through fetch" do
      type, _post = evaluate(<<~RUBY)
        h = { a: 1, b: 2 }
        h.fetch(:a)
      RUBY
      # Slice 5 phase 2 picks the precise value for the static key.
      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "shape-aware dispatch (Slice 5 phase 2)" do
    it "returns the precise tuple element for `tuple[i]`" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs[1]
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "returns the precise tuple element for negative indices" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs[-1]
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "returns a sliced Tuple for tuple[start, length]" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs[1, 2]
      RUBY
      expect(type).to eq(
        Rigor::Type::Combinator.tuple_of(
          Rigor::Type::Combinator.constant_of(2),
          Rigor::Type::Combinator.constant_of(3)
        )
      )
    end

    it "returns a sliced Tuple for tuple[range]" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs[1..]
      RUBY
      expect(type).to eq(
        Rigor::Type::Combinator.tuple_of(
          Rigor::Type::Combinator.constant_of(2),
          Rigor::Type::Combinator.constant_of(3)
        )
      )
    end

    it "returns Constant[size] for tuple.size" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs.size
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "returns the first element rather than the projected union for tuple.first" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs.first
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "returns the last element for tuple.last" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs.last
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "falls back to the projected union for out-of-range tuple indices" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs[100]
      RUBY
      # The shape tier defers; RbsDispatch returns Array#[]'s projected
      # type, which is Elem | nil under the value-lattice.
      expect(type).not_to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "returns the precise value for hash_shape[k] with a static key" do
      type, _post = evaluate(<<~RUBY)
        h = { a: 1, b: "two" }
        h[:b]
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of("two"))
    end

    it "returns Constant[nil] for hash_shape[missing_key]" do
      type, _post = evaluate(<<~RUBY)
        h = { a: 1 }
        h[:missing]
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    it "returns the precise dig value for a single static key" do
      type, _post = evaluate(<<~RUBY)
        h = { a: 1 }
        h.dig(:a)
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "block parameter binding (Slice 6 phase C sub-phase 1)" do
    let(:default_env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

    def watch_local_reads(name)
      events = []
      on_enter = lambda do |node, s|
        next unless node.is_a?(Prism::LocalVariableReadNode) && node.name == name

        events << s.local(name)
      end
      [events, on_enter]
    end

    def run_eval(base_scope, on_enter, source)
      described_class.new(scope: base_scope, on_enter: on_enter).evaluate(parse_program(source))
    end

    it "binds the block parameter as the tuple element union for Array[Tuple]#each" do
      events, on_enter = watch_local_reads(:x)
      run_eval(default_env_scope, on_enter, "[1, 2, 3].each { |x| x }")
      # `[1, 2, 3]` carries `Tuple[Constant[1], Constant[2], Constant[3]]`,
      # which projects to `Array[Constant[1] | Constant[2] | Constant[3]]`
      # for dispatch; the block's `Elem` parameter therefore binds to
      # the same union.
      expect(events).not_to be_empty
      expect(events.first).to be_a(Rigor::Type::Union)
      expect(events.first.members).to contain_exactly(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2),
        Rigor::Type::Combinator.constant_of(3)
      )
    end

    it "binds the block parameter as Integer when the receiver is Array[Integer] (no shape)" do
      events, on_enter = watch_local_reads(:x)
      bound = default_env_scope.with_local(
        :nums,
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("Integer")])
      )
      ast = Prism.parse("nums.each { |x| x }", scopes: [[:nums]]).value
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)
      expect(events).not_to be_empty
      expect(events.first).to be_a(Rigor::Type::Nominal)
      expect(events.first.class_name).to eq("Integer")
    end

    it "binds multiple block parameters in declaration order" do
      events_k, watch_k = watch_local_reads(:k)
      events_v, watch_v = watch_local_reads(:v)
      combined = lambda do |node, s|
        watch_k.call(node, s)
        watch_v.call(node, s)
      end
      run_eval(default_env_scope, combined, "{ a: 1, b: 2 }.each { |k, v| k; v }")
      # The receiver is a HashShape{a: 1, b: 2}; Hash#each yields
      # `[K, V]` tuples and the binder receives the tuple slot type
      # for each positional. We assert that the bindings are present
      # rather than the exact tuple shape (which can vary across
      # RBS revisions).
      expect(events_k.first).not_to be_nil
      expect(events_v.first).not_to be_nil
    end

    it "defaults block parameters to Dynamic[Top] when the receiver has no RBS signature" do
      events, on_enter = watch_local_reads(:x)
      # `foo` resolves to an implicit-self call without a known
      # signature. The block param falls back to Dynamic[Top].
      run_eval(default_env_scope, on_enter, "foo { |x| x }")
      expect(events).not_to be_empty
      expect(events.first).to eq(Rigor::Type::Combinator.untyped)
    end

    it "does not leak block-local writes into the post-call scope" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        [1, 2, 3].each { |x| inner = x }
      RUBY
      expect(post.local(:inner)).to be_nil
    end

    it "threads block parameter bindings through statements within the block body" do
      events, on_enter = watch_local_reads(:x)
      run_eval(default_env_scope, on_enter, "[1, 2, 3].each { |x| y = x; x }")
      # `x` is read twice; the binding must stay the tuple element
      # union (Constant[1]|Constant[2]|Constant[3]) throughout.
      expect(events.size).to be >= 2
      expect(events.last.members).to contain_exactly(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2),
        Rigor::Type::Combinator.constant_of(3)
      )
    end

    it "evaluates the block body's terminal statement under the bound block param" do
      # `n + 1` is itself a CallNode, so the inner `n` read does not
      # fire `on_enter`; we probe the entry scope at the CallNode
      # level instead, which sees the bound `n` via `type_of`.
      events = []
      on_enter = lambda do |node, s|
        next unless node.is_a?(Prism::CallNode) && node.name == :+

        events << s.type_of(node.receiver)
      end
      run_eval(default_env_scope, on_enter, "[1, 2, 3].map { |n| n + 1 }")
      expect(events.first).to be_a(Rigor::Type::Union)
    end

    it "does not crash on numbered-block parameters (`_1`)" do
      expect do
        default_env_scope.evaluate(parse_program("[1, 2, 3].each { _1.succ }"))
      end.not_to raise_error
    end
  end

  describe "closure escape fact recording (Slice 6 phase C sub-phase 3b)" do
    let(:default_env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

    def closure_escape_facts(post)
      post.facts_for(bucket: :dynamic_origin).select { |f| f.predicate == :closure_escape }
    end

    it "leaves the post-scope fact_store untouched for non-escaping core iteration" do
      _, post = default_env_scope.evaluate(parse_program("[1, 2, 3].each { |x| x }"))
      expect(closure_escape_facts(post)).to be_empty
    end

    it "leaves the fact_store untouched for Object#tap on any receiver" do
      _, post = default_env_scope.evaluate(parse_program("\"hi\".tap { |s| s }"))
      expect(closure_escape_facts(post)).to be_empty
    end

    it "records a dynamic_origin closure_escape fact for known escaping methods" do
      _, post = default_env_scope.evaluate(parse_program("Thread.new { 1 }"))
      facts = closure_escape_facts(post)
      expect(facts.size).to eq(1)
      expect(facts.first.payload).to include(method_name: :new, classification: :escaping)
      expect(facts.first.target.kind).to eq(:closure)
      expect(facts.first.target.name).to eq(:new)
    end

    it "records :unknown classification when the receiver is uncatalogued" do
      _, post = default_env_scope.evaluate(parse_program("foo.bar { |x| x }"))
      facts = closure_escape_facts(post)
      expect(facts.size).to eq(1)
      expect(facts.first.payload[:classification]).to eq(:unknown)
    end

    it "does not record a fact for block-less calls" do
      _, post = default_env_scope.evaluate(parse_program("foo.bar(1, 2)"))
      expect(closure_escape_facts(post)).to be_empty
    end
  end

  describe "captured-local invalidation on closure escape (Slice 6 phase C sub-phase 3c)" do
    let(:default_env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

    def integer_constant(value) = Rigor::Type::Combinator.constant_of(value)

    it "preserves captured-local types across non-escaping iteration" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        x = 1
        [1, 2, 3].each { |n| n }
      RUBY
      expect(post.local(:x)).to eq(integer_constant(1))
    end

    it "drops the narrowed type of an outer local that an escaping block writes" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        x = 1
        Thread.new { x = 2 }
      RUBY
      expect(post.local(:x)).to be_a(Rigor::Type::Dynamic)
      expect(post.local(:x).static_facet).to be_a(Rigor::Type::Top)
    end

    it "leaves outer locals the escaping block only reads untouched" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        x = 1
        Thread.new { x }
      RUBY
      expect(post.local(:x)).to eq(integer_constant(1))
    end

    it "respects block-parameter shadowing (write to a parameter is not a captured rebind)" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        x = 1
        Thread.new { |x| x = 99 }
      RUBY
      expect(post.local(:x)).to eq(integer_constant(1))
    end

    it "drops captured locals on :unknown classification too" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        x = 1
        foo.bar { x = 2 }
      RUBY
      expect(post.local(:x)).to be_a(Rigor::Type::Dynamic)
    end

    it "invalidates the local_binding fact on the dropped local" do
      # Pre-bind x with a fact, then escape; the with_local call inside
      # the drop must invalidate the local_binding bucket entry.
      base = default_env_scope.with_local(:x, integer_constant(1))
      base = base.with_fact(
        Rigor::Analysis::FactStore::Fact.new(
          bucket: :local_binding,
          target: Rigor::Analysis::FactStore::Target.local(:x),
          predicate: :is_int
        )
      )
      _, post = base.evaluate(parse_program("Thread.new { x = 2 }"))
      expect(post.local_facts(:x, bucket: :local_binding)).to be_empty
    end
  end
end
