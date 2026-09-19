# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/optimistic_origin"

# ADR-101. Every decline assertion here is paired with a case that MUST still elide: a decline is the
# easiest expectation in this repo to pass by accident, because any construction error also widens the
# type. The proof-side examples are the control, not decoration — if they stop eliding, the gate has
# become a blanket "never elide" and the declines below prove nothing.
RSpec.describe Rigor::Inference::OptimisticOrigin do
  let(:scope) { Rigor::Scope.empty }

  def evaluate(source)
    scope.evaluate(Prism.parse(source).value)
  end

  # Bind a carrier directly rather than reaching for a stdlib expression that happens to produce it. The
  # gemspec supports `rbs >= 3.0, < 5.0` and the two lines disagree on some core signatures (`ENV` among
  # them), so a fixture that infers its own carrier can fail for a reason that has nothing to do with the
  # behaviour under test. `Array` is used because `Array#first` carries the annotation on both lines.
  def evaluate_with(locals, source)
    base = locals.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
    base.evaluate(Prism.parse(source, scopes: [locals.keys]).value)
  end

  def array_of_string
    Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")])
  end

  def arms_of(type)
    return [type.value] if type.is_a?(Rigor::Type::Constant)

    type.members.map { |member| member.is_a?(Rigor::Type::Constant) ? member.value : member.describe }
  end

  describe "the cause it carries" do
    it "names the core-RBS annotation the dispatcher reads past" do
      expect(described_class::ANNOTATION).to eq("implicitly-returns-nil")
      expect(described_class::IMPLICITLY_RETURNS_NIL).to eq(:implicitly_returns_nil)
    end
  end

  describe "declines the elision when nil-freeness is a bet" do
    it "keeps both arms on a Union from a dynamic-key Hash read" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "keeps both arms when the read yields a single Constant, which no carrier-shape gate can see" do
      # Every value of the hash shares one type, so `V` is a lone `Constant["x"]` — exactly as optimistic
      # as the union above, and indistinguishable from a genuine constant without provenance.
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "x" }
        v = h[key]
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "keeps both arms on a Nominal from `Array#first`" do
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        v = xs.first
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines when the predicate is the read itself, with no intervening binding" do
      # A distinct path from the cases around it: the mark is read off the call node rather than off a
      # binding, so this pins the node-keyed side of the channel.
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        if h[key] then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "propagates the mark through an instance variable" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        @v = h[key]
        if @v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "propagates the mark through a local-to-local copy" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        w = v
        if w then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines `unless` on the same carrier" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        unless v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end
  end

  # Issue #313. The mark attaches to a value, but every consumer reads a predicate *expression*, and the
  # guard people actually write is `v.nil?` rather than the bare carrier. Each of these shapes folded to an
  # unmarked `Constant` before the derivation, so the elision deleted the branch the program takes on a miss.
  describe "derives the mark through the predicate fold" do
    it "declines through `.nil?`" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        if v.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through a `||` composition of two `.nil?` guards" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        w = h[other]
        if v.nil? || w.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through a `&&` composition of two negated `.nil?` guards" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        w = h[other]
        if !v.nil? && !w.nil? then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines when only one operand of the composition is optimistic" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        s = "abc".upcase
        if s.nil? || v.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through a parenthesised guard" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        if (v.nil?) then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "carries the derived mark onto a local bound to the guard's result" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        missing = v.nil?
        if missing then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    # The control side of the derivation: the same syntax over proof-carrying carriers MUST still elide,
    # otherwise the four declines above are passing because `.nil?` stopped folding at all.
    it "still elides `.nil?` over a proof-carrying carrier" do
      type, = evaluate(<<~RUBY)
        v = "abc".upcase
        if v.nil? then "none" else 1 end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides a `||` composition over proof-carrying carriers" do
      type, = evaluate(<<~RUBY)
        v = "abc".upcase
        w = "def".upcase
        if v.nil? || w.nil? then "none" else 1 end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides a `&&` composition of negated guards over proof-carrying carriers" do
      type, = evaluate(<<~RUBY)
        v = "abc".upcase
        w = "def".upcase
        if !v.nil? && !w.nil? then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides `.nil?` over a static-key read, which cannot miss" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[:a]
        if v.nil? then "none" else 1 end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    # Issue #1094 — `v == nil` is `v.nil?` spelled as a comparison, on either side and through every equality
    # operator. Paired with the proof-carrying control below and the non-nil comparison that must not derive.
    it "declines through a comparison with the nil literal, either side and every equality spelling" do
      ["v == nil", "nil == v", "v != nil", "nil != v", "v.eql?(nil)", "v.equal?(nil)", "nil === v"].each do |guard|
        type, = evaluate(<<~RUBY)
          h = { a: "x", b: "y" }
          v = h[key]
          if #{guard} then "none" else 1 end
        RUBY

        expect(arms_of(type)).to contain_exactly(1, "none"), "for #{guard}"
      end
    end

    it "still elides a comparison with the nil literal over a proof-carrying carrier" do
      type, = evaluate(<<~RUBY)
        v = "abc".upcase
        if v == nil then "none" else 1 end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "does not derive through a comparison with a non-nil value or with an argument list that is not one nil" do
      node = Prism.parse("v == 1").value.statements.body.first
      scope_with_mark = scope.with_local(:v, Rigor::Type::Combinator.nominal_of("String"))
                             .with_optimistic_local(:v, described_class::IMPLICITLY_RETURNS_NIL)
      expect(described_class.resolve(node, scope_with_mark)).to be_nil
      both_nil = Prism.parse("nil == nil").value.statements.body.first
      expect(described_class.resolve(both_nil, scope_with_mark)).to be_nil
      guard = Prism.parse("v == nil", scopes: [[:v]]).value.statements.body.first
      expect(described_class.resolve(guard, scope_with_mark)).to eq(described_class::IMPLICITLY_RETURNS_NIL)
    end

    it "does not derive through a value predicate, which is not a statement about nil-ness" do
      # `empty?` folds from the carrier's *value*, and the mark is about its nil-freeness only. Deriving
      # through it would widen this channel into a general taint and silence honest verdicts.
      expect(described_class::NIL_COLLAPSING_PREDICATES).to contain_exactly(:nil?, :!)
    end
  end

  # The `&&` / `||` value-position gate, the second of the three consumers the spec binds. Its failure mode
  # is not a diagnostic but a discarded operand: `MAP[key] || key` is written because the lookup can miss.
  describe "the `&&` / `||` value-polarity gate" do
    def type_of_last_write(source)
      ast = Prism.parse(source).value
      _type, after = scope.evaluate(ast)
      target = nil
      collect = lambda do |node|
        return unless node.is_a?(Prism::Node)

        target = node.value if node.is_a?(Prism::LocalVariableWriteNode) && node.name == :probe
        node.compact_child_nodes.each { |child| collect.call(child) }
      end
      collect.call(ast)
      after.type_of(target)
    end

    it "keeps the author's fallback when the left operand is optimistically nil-free" do
      # A uniform-valued literal hash reads as a lone `Constant`, so the `Constant`-only gate cannot see the
      # difference — this is the `MAP[key] || key` counter-example the spec names.
      type = type_of_last_write(<<~RUBY)
        h = { a: 1, b: 1 }
        probe = h[key] || 5
      RUBY

      expect(arms_of(type)).to contain_exactly(1, 5)
    end

    it "still short-circuits on a genuine constant left operand (the control)" do
      type = type_of_last_write("probe = 1 || 5")

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "still elides when nil-freeness is a property of the value (the control)" do
    it "elides on a Nominal whose class excludes nil — the same carrier class as the declining case" do
      # The pair that carries this ADR: `xs.first` above and `xs` here are the same carrier class, and only
      # provenance separates them. If this stops eliding, the gate has become a blanket "never elide".
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        if xs then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on a genuine Constant" do
      type, = evaluate(<<~RUBY)
        v = "abc".upcase
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on a literal predicate" do
      type, = evaluate('if true then 1 else "none" end')

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on a static-key read, which `ShapeDispatch` resolves precisely rather than optimistically" do
      type, = evaluate(<<~RUBY)
        h = { a: "x" }
        v = h[:a]
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on `Array#first` over a Tuple, where the receiver proves the read cannot miss" do
      type, = evaluate(<<~RUBY)
        v = ["a", "b"].first
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "rebinding a local to a proof-carrying value clears the mark" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        v = "abc".upcase
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "a carrier that is honestly optional still declines, for its own reason" do
    it "keeps both arms on an RBS-declared optional return" do
      type, = evaluate(<<~RUBY)
        v = "abc".match(/x/)
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end
  end

  # Issue #1093 — a short array pads a destructured slot with `nil`, so `a, b = xs` binds each fixed slot
  # to `T` under the same bet as `xs.first`, on the statement and the block surface alike.
  describe "destructuring an Array[T]" do
    def array_of_array_of_string
      Rigor::Type::Combinator.nominal_of("Array", type_args: [array_of_string])
    end

    it "declines on a statement-level fixed slot, matching `xs.first`" do
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        a, b = xs
        if b.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on a trailing slot after a rest" do
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        *init, last = xs
        if last then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on an auto-splatted block parameter" do
      type, = evaluate_with({ xs: array_of_array_of_string }, <<~RUBY)
        xs.map { |g, h| if h then 1 else "none" end }
      RUBY

      expect(type.describe).to eq(Rigor::Type::Combinator.nominal_of(
        "Array", type_args: [Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of("none")
        )]
      ).describe)
    end

    it "still elides on a Tuple slot, whose element is known to be present" do
      type, = evaluate(<<~RUBY)
        a, b = ["x", "y"]
        if b then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    # Issue #1094 — a union right-hand side marks a name when any member marked it, so the Array member's
    # short-array bet survives a join with a Tuple member whose slot is present.
    it "declines on a slot a union's Array[T] member marked, even joined with a present Tuple slot" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"),
                                               Rigor::Type::Combinator.nominal_of("String"))
      mixed = Rigor::Type::Combinator.union(tuple, array_of_string)
      type, = evaluate_with({ xs: mixed }, <<~RUBY)
        a, b = xs
        if b.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on a slot softened from `Array[T] | nil`, whose nil member wraps to [nil]" do
      optional = Rigor::Type::Combinator.union(array_of_string, Rigor::Type::Combinator.constant_of(nil))
      type, = evaluate_with({ xs: optional }, <<~RUBY)
        a, b = xs
        if a then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines `== nil` / `!= nil` on a slot softened out of a union (the #1094 review repros)" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of("x"),
                                               Rigor::Type::Combinator.constant_of("y"))
      found = Rigor::Type::Combinator.union(tuple, Rigor::Type::Combinator.constant_of(nil))
      { "if k == nil then \"none\" else 1 end" => [1, "none"],
        "if k != nil then 1 else \"none\" end" => [1, "none"] }.each do |guard, arms|
        type, = evaluate_with({ found: found }, "k, v = found\n#{guard}\n")
        expect(arms_of(type)).to match_array(arms), "for #{guard}"
      end
    end

    # Issue #1110 — an instance-variable target takes the same bet, recorded through `Scope#with_optimistic_ivar`.
    it "declines on an instance-variable fixed slot, matching `@x = xs.first`" do
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        @a, @b = xs
        if @b.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "still elides on an instance-variable Tuple slot" do
      type, = evaluate(<<~RUBY)
        @a, @b = ["x", "y"]
        if @b then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on the nil slot of a wrapped scalar, which is exact rather than a bet" do
      type, = evaluate(<<~RUBY)
        a, b = 1
        if b then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of("none"))
    end

    it "still elides on a statement-level rest, which is an Array even when the source is short" do
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        a, *rest = xs
        if rest then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end
end
