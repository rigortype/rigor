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

  # `Hash[Symbol, V]`, whose computed-key `[]` is the read `RbsDispatch` types past the annotation. A literal
  # hash cannot stand in for it: its closed shape answers a computed key itself, with the nil arm the miss
  # produces, so a fixture built on one would pass these declines with no mark recorded at all.
  def hash_of(*values)
    value = Rigor::Type::Combinator.union(*values.map { |v| Rigor::Type::Combinator.constant_of(v) })
    Rigor::Type::Combinator.nominal_of("Hash", type_args: [Rigor::Type::Combinator.nominal_of("Symbol"), value])
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
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "keeps both arms when the read yields a single Constant, which no carrier-shape gate can see" do
      # Every value of the hash shares one type, so `V` is a lone `Constant["x"]` — exactly as optimistic
      # as the union above, and indistinguishable from a genuine constant without provenance.
      type, = evaluate_with({ h: hash_of("x") }, <<~RUBY)
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

    it "keeps both arms on an `&&=` that stores through an optimistic read" do
      # `xs[i] &&= "y"` stores nothing when the slot is absent, so its value is `nil` there: the mark the
      # implicit `[]` read carries is the write's too.
      integer = Rigor::Type::Combinator.nominal_of("Integer")
      type, = evaluate_with({ xs: array_of_string, i: integer }, <<~RUBY)
        if (xs[i] &&= "y") then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines when the predicate is the read itself, with no intervening binding" do
      # A distinct path from the cases around it: the mark is read off the call node rather than off a
      # binding, so this pins the node-keyed side of the channel.
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        if h[key] then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "propagates the mark through an instance variable" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        @v = h[key]
        if @v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "propagates the mark through a local-to-local copy" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        w = v
        if w then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines `unless` on the same carrier" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
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
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        if v.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through a `||` composition of two `.nil?` guards" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        w = h[other]
        if v.nil? || w.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through a `&&` composition of two negated `.nil?` guards" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        w = h[other]
        if !v.nil? && !w.nil? then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines when only one operand of the composition is optimistic" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        s = "abc".upcase
        if s.nil? || v.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through a parenthesised guard" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        if (v.nil?) then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "carries the derived mark onto a local bound to the guard's result" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
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
        type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
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

  # Issue #1172 — the derivation above lets the in-scope consumers decline, but it does not change the
  # predicate call's *type*: `v.nil?` still answered `Constant[false]`. A type is what a method's return
  # summary carries across the boundary, and the mark is not — so a helper ending in `!h[k].nil?`
  # published `Constant[true]`, and the caller's `if helper(...)` reported `flow.always-truthy-condition`
  # on a guard that is live at run time. The predicate's answer is `bool` when a mark derives, so nothing
  # proof-shaped crosses the boundary.
  describe "the predicate's own type answer does not fold on a marked carrier" do
    it "answers `bool`, not `false`, for `.nil?` on an optimistically nil-free carrier" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        v.nil?
      RUBY

      expect(type.describe).to eq("bool")
    end

    it "answers `bool`, not `true`, for `!` applied to a marked carrier's `.nil?`" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]
        !v.nil?
      RUBY

      expect(type.describe).to eq("bool")
    end

    it "does not let the fold reach a caller through a method's return summary", type: :runner do
      # `Scope#evaluate` alone does not run inter-procedural inference, so the boundary case needs the
      # Runner: the helper's `!h[k].nil?` published `Constant[true]` before the fix, and the caller's
      # `if duck?(...)` reported `flow.always-truthy-condition` on a guard a missing key makes live. The
      # table is declared rather than assigned a literal, whose shape would answer the read with its nil arm.
      diagnostics = analyze(<<~RUBY, sig: { "table.rbs" => "TABLE: Hash[Symbol, Integer]\n" }).diagnostics
        def duck?(k)
          !TABLE[k].nil?
        end
        if duck?(k)
          puts "yes"
        end
      RUBY

      expect(diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }).to be_empty
    end

    it "still folds `.nil?` on a proof-carrying carrier (the control)" do
      type, = evaluate(<<~RUBY)
        v = "abc".upcase
        v.nil?
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(false))
    end
  end

  # The `&&` / `||` value-position gate, the second of the three consumers the spec binds. Its failure mode
  # is not a diagnostic but a discarded operand: `MAP[key] || key` is written because the lookup can miss.
  describe "the `&&` / `||` value-polarity gate" do
    def type_of_last_write(source, locals = {})
      ast = Prism.parse(source, scopes: [locals.keys]).value
      base = locals.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
      _type, after = base.evaluate(ast)
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
      # A uniform-valued hash reads as a lone `Constant`, so the `Constant`-only gate cannot see the
      # difference — this is the `MAP[key] || key` counter-example the spec names.
      type = type_of_last_write(<<~RUBY, { h: hash_of(1) })
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

    it "elides on an `&&=` through a Tuple slot, whose element is known to be present" do
      type, = evaluate(<<~RUBY)
        t = ["a"]
        if (t[0] &&= "y") then 1 else "none" end
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
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
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

  # A multiple assignment from an optimistically nil-free value binds `nil` to every fixed slot on a miss
  # (`k, v = nil`), so each slot's nil-freeness is the same bet; a literal right-hand side hands each slot its
  # own element's. A plain element read is the boundary: `pairs.first.last` raises on a miss rather than
  # producing a value, so it keeps eliding, while `pairs.first&.last` is `nil` exactly on the miss — and
  # `&.` skips only that one call, so `pairs.first&.last.abs` raises on the miss and keeps eliding too.
  describe "destructuring or safe-navigating an optimistically nil-free value" do
    def pairs
      pair = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"),
                                              Rigor::Type::Combinator.nominal_of("Integer"))
      Rigor::Type::Combinator.nominal_of("Array", type_args: [pair])
    end

    it "declines on every fixed slot of a destructured `Array#first`" do
      %w[k v].each do |slot|
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          k, v = pairs.first
          if #{slot} then 1 else "none" end
        RUBY

        expect(arms_of(type)).to contain_exactly(1, "none"), "for #{slot}"
      end
    end

    it "declines when the destructured value was first bound to a local" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        pair = pairs.first
        k, _v = pair
        if k then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through `.nil?` on a destructured slot" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        k, _v = pairs.first
        if k.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on an instance-variable slot of a destructured `Array#first`" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        @k, _v = pairs.first
        if @k then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on the slot a literal right-hand side fills from the marked element" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        x, _y = pairs.first, 1
        if x then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on a nested target under the marked element of a literal right-hand side" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        (k, _v), _w = pairs.first, 1
        if k then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on a trailing slot a literal right-hand side fills from the marked element after a rest" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        _a, *_mid, z = 1, 2, pairs.first
        if z then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on a safe-navigation read of the carrier" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        if pairs.first&.last then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines through `.nil?` over a safe-navigation read" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        if pairs.first&.last.nil? then "none" else 1 end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines on a local bound to a safe-navigation read of a dynamic-key Hash read" do
      type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
        v = h[key]&.upcase
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "still elides on a plain element read, which raises on a miss rather than producing nil" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        if pairs.first.last then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on a plain call chained after the safe navigation, which Ruby sends to the nil and raises" do
      # `&.` skips only the one call: on a miss `pairs.first&.last.abs` is `nil.abs`, a NoMethodError.
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        if pairs.first&.last.abs then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on a safe-navigation read of a proof-carrying receiver" do
      type, = evaluate_with({ s: Rigor::Type::Combinator.nominal_of("String") }, <<~RUBY)
        if s&.upcase then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on the slot a literal right-hand side fills from an unmarked element" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        _x, y = pairs.first, 1
        if y then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides when a later unmarked slot rebinds the name a marked slot bound" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        a, a = pairs.first, 1
        if a then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on a local bound to a whole literal element, which is an Array even on a miss" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        x, _y = [pairs.first], 1
        if x then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on the unmarked sibling of a nested target under a marked element" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        (_k, _v), w = pairs.first, 1
        if w then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on a slot past the destructured pair's end, which is nil on a hit too" do
      type, = evaluate_with({ pairs: pairs }, <<~RUBY)
        _k, _v, w = pairs.first
        if w then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of("none"))
    end

    it "keeps a safe-navigation predicate's own `true`, since the miss answers nil rather than false" do
      type, = evaluate_with({ pairs: pairs }, "pairs.first&.last&.integer?\n")

      expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
    end

    it "keeps `!` over a safe-navigation predicate that a miss answers the same way" do
      # Hit: `!false`; miss: `!nil`. Both are `true`, so `bool` would invent a `false`.
      type, = evaluate_with({ pairs: pairs }, "!pairs.first&.empty?\n")

      expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
    end

    it "still widens `!!` over a marked read, whose miss answers the other boolean" do
      type, = evaluate_with({ h: hash_of("x") }, "!!h[key]\n")

      expect(type.describe).to eq("bool")
    end

    it "still widens `.nil?` over a safe-navigation read, which a miss flips" do
      type, = evaluate_with({ pairs: pairs }, "pairs.first&.last.nil?\n")

      expect(type.describe).to eq("bool")
    end

    it "still elides on a destructured literal pair, whose slots are known to be present" do
      type, = evaluate(<<~RUBY)
        k, _v = ["x", 1]
        if k then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "still elides on the rest of a destructured `Array#first`, which is an Array even on a miss" do
      type, scope_after = evaluate_with({ pairs: pairs }, <<~RUBY)
        _k, *rest = pairs.first
        if rest then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
      # A miss makes the rest `[]`, so it is the arity-free `Array`, not the one-element Tuple of the pair.
      expect(scope_after.local(:rest).describe).to eq("Array[Integer]")
    end

    # Issue #1302 — the binding records what the bound value answers on a miss next to its mark, so a
    # predicate read through the local or ivar widens exactly as far as its inline form does. Every keep
    # below is paired with a binding whose miss answers the other boolean, or cannot be told, and still
    # widens.
    describe "a predicate read through the binding it was stored in" do
      it "keeps `!` over a local bound to a safe-navigation predicate, as the inline form does" do
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          x = pairs.first&.empty?
          !x
        RUBY

        expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "keeps `!` over an instance variable bound to a safe-navigation predicate" do
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          @x = pairs.first&.empty?
          !@x
        RUBY

        expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "keeps the answer through a copy of the binding" do
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          x = pairs.first&.empty?
          y = x
          !y
        RUBY

        expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "keeps the answer through a destructured slot, which a miss fills with nil" do
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          a, _b = pairs.first&.empty?
          !a
        RUBY

        expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "still widens `.nil?` and `!` over a local bound to a dynamic-key Hash read (the #1172 control)" do
        %w[v.nil? !v].each do |predicate|
          type, = evaluate_with({ h: hash_of("x", "y") }, <<~RUBY)
            v = h[key]
            #{predicate}
          RUBY

          expect(type.describe).to eq("bool"), "for #{predicate}"
        end
      end

      it "keeps `.nil?` over a binding whose miss answers `false`, and widens it over one whose miss is nil" do
        # `!!recv&.empty?` is `false` on a hit and on a miss; `recv&.empty?` is `nil` on a miss.
        kept, = evaluate_with({ pairs: pairs }, "x = !!pairs.first&.empty?\nx.nil?\n")
        widened, = evaluate_with({ pairs: pairs }, "x = pairs.first&.empty?\nx.nil?\n")

        expect(kept).to eq(Rigor::Type::Combinator.constant_of(false))
        expect(widened.describe).to eq("bool")
      end

      it "drops the recorded answer when the local is rebound, marked or not" do
        type, after = evaluate_with({ pairs: pairs }, <<~RUBY)
          x = !!pairs.first&.empty?
          x = pairs.first&.empty?
          x.nil?
        RUBY

        expect(type.describe).to eq("bool")
        expect(after.optimistic_local_miss(:x)).to be_nil
        _, unmarked = evaluate_with({ pairs: pairs }, "x = !!pairs.first&.empty?\nx = false\n")
        expect(unmarked.optimistic_local_miss(:x)).to be(described_class::UNKNOWN_MISS)
      end

      it "widens after a join whose branches record different answers" do
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          if c
            x = !!pairs.first&.empty?
          else
            x = pairs.first&.empty?
          end
          x.nil?
        RUBY

        expect(type.describe).to eq("bool")
      end

      it "keeps the marked branch's answer after a join with an unmarked branch" do
        # The miss path runs only through the marked branch, and the unmarked `false` answers `true` too.
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          if c
            x = pairs.first&.empty?
          else
            x = false
          end
          !x
        RUBY

        expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "keeps the answer across a block that rebinds the local to an unmarked value" do
        type, = evaluate_with({ pairs: pairs }, <<~RUBY)
          x = pairs.first&.empty?
          pairs.each { x = false }
          !x
        RUBY

        expect(type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "widens across a block whose own rebind marks the local with another answer" do
        type, = evaluate_with({ pairs: pairs, h: hash_of("x") }, <<~RUBY)
          x = pairs.first&.empty?
          pairs.each { x = !h[key] }
          !x
        RUBY

        expect(type.describe).to eq("bool")
      end

      it "reports no return-type mismatch for the bound form under a declared `true`", type: :runner do
        sig = <<~RBS
          class Probe
            def pairs: () -> Array[[String, Integer]]
            def present?: () -> true
          end
        RBS
        diagnostics = analyze(<<~RUBY, sig: { "probe.rbs" => sig }).diagnostics
          class Probe
            def pairs = []

            def present?
              x = pairs.first&.empty?
              !x
            end
          end
        RUBY

        expect(diagnostics.map(&:rule)).not_to include("def.return-type-mismatch")
      end
    end
  end

  describe ".resolve through a safe-navigation call" do
    let(:marked) do
      scope.with_local(:v, Rigor::Type::Combinator.nominal_of("String"))
           .with_optimistic_local(:v, described_class::IMPLICITLY_RETURNS_NIL)
    end

    def expression(source)
      Prism.parse(source, scopes: [[:v]]).value.statements.body.first
    end

    it "resolves `v&.m`, `v&.m&.n` and `v&.m.nil?` to the receiver's mark" do
      %w[v&.upcase v&.upcase&.size v&.upcase(1) v&.upcase.nil?].each do |source|
        expect(described_class.resolve(expression(source), marked))
          .to eq(described_class::IMPLICITLY_RETURNS_NIL), "for #{source}"
      end
    end

    it "does not resolve a plain read, a plain call chained after `&.`, or an argument's safe navigation" do
      %w[v.upcase v&.upcase.size v&.upcase(1).size (v&.upcase).size foo(v&.upcase)].each do |source|
        expect(described_class.resolve(expression(source), marked)).to be_nil, "for #{source}"
      end
    end
  end

  describe ".destructuring_marks" do
    let(:marked) do
      scope.with_local(:v, Rigor::Type::Combinator.nominal_of("String"))
           .with_optimistic_local(:v, described_class::IMPLICITLY_RETURNS_NIL)
    end

    def value_of(source)
      Prism.parse(source, scopes: [[:v]]).value.statements.body.first.value
    end

    it "answers true for a marked right-hand side, element marks for a literal one, and false otherwise" do
      expect(described_class.destructuring_marks(value_of("a, b = v"), marked)).to be(true)
      expect(described_class.destructuring_marks(value_of("a, b = 1, v"), marked)).to eq([false, true])
      expect(described_class.destructuring_marks(value_of("a, (b, c) = 1, [v, 2]"), marked))
        .to eq([false, [true, false]])
      expect(described_class.destructuring_marks(value_of("a, b = 1, 2"), marked)).to be(false)
      expect(described_class.destructuring_marks(value_of("a, b = *v, v"), marked)).to be(false)
    end
  end

  describe ".destructuring_miss" do
    # `v` records a `nil` miss, as `v = h[k]` does; `w` is marked with no recorded answer.
    let(:marked) do
      string = Rigor::Type::Combinator.nominal_of("String")
      scope.with_local(:v, string).with_optimistic_local(:v, described_class::IMPLICITLY_RETURNS_NIL, miss: nil)
           .with_local(:w, string).with_optimistic_local(:w, described_class::IMPLICITLY_RETURNS_NIL)
    end

    def value_of(source)
      Prism.parse(source, scopes: [%i[v w]]).value.statements.body.first.value
    end

    it "answers nil when every marked part of the right-hand side is nil on a miss" do
      ["a, b = v", "a, b = 1, v", "a, (b, c) = 1, [v, 2]", "a, b = 1, 2"].each do |source|
        expect(described_class.destructuring_miss(value_of(source), marked)).to be_nil, "for #{source}"
      end
    end

    it "answers unknown when a marked part is a boolean on a miss, or its answer cannot be told" do
      ["a, b = !v", "a, b = 1, v.nil?", "a, b = w", "a, b = v, w"].each do |source|
        expect(described_class.destructuring_miss(value_of(source), marked))
          .to be(described_class::UNKNOWN_MISS), "for #{source}"
      end
    end
  end
end
