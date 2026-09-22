# frozen_string_literal: true

require "spec_helper"

# Issue #1125 — the user-method call-site binder (`ExpressionTyper#call_arg_types` feeding
# `#bind_params_from_call_types`) reads two call shapes it used to decline outright:
#
# - a keyword hash built entirely from a double splat (`target(**h)`, `h` a closed `HashShape`), and
# - `...` forwarding (`def forward(...) = target(...)`), whose forwarded argument list is the
#   forwarding method's own call site.
#
# Exercised through the full runner, so the assertions are on the type the engine actually reports and
# the ADR-84 return memo — whose key is `(def_node, receiver, arg_types)` — is on the path.
#
# The engine's own `assert.type-mismatch` rule is the assertion channel: the fixture states the
# expected type, so an empty mismatch list means the engine answered exactly that. A fixture asserting
# `Dynamic[top]` therefore PINS the pre-#1125 answer for the shapes this change declines.
RSpec.describe "issue #1125 — keyword-splat and `...` call-site binding" do
  include RunnerHelpers

  def type_mismatches(source)
    analyze(source).diagnostics.select { |d| d.rule == "assert.type-mismatch" }.map(&:message)
  end

  def all_diagnostics(source)
    analyze(source).diagnostics.map { |d| [d.rule, d.message] }.sort
  end

  def expect_binds(source)
    expect(type_mismatches(source)).to be_empty
  end

  describe "a double-splatted hash shape" do
    it "binds the same parameters the literal keyword call binds" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:, **rest) = [a, b, rest]
        h = { a: 1, b: 2 }
        splatted = target(**h)
        literal = target(a: 1, b: 2)
        assert_type("[1, 2, Dynamic[top]]", splatted)
        assert_type("[1, 2, Dynamic[top]]", literal)
      RUBY
    end

    it "binds a positional parameter alongside the keyword tail" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a, b, **rest) = [a, b, rest]
        h = { c: "z" }
        t = target(1, 2, **h)
        assert_type("[1, 2, { c: \\"z\\" }]", t)
      RUBY
    end

    it "keeps the pre-#1125 answer for a shapeless Hash[Symbol, V] and for an opaque value" do
      # The acceptance's declined shapes: a keyword hash whose keys are unknown is not a shape, so the
      # binder must NOT guess which key feeds which parameter — `Dynamic[top]` stands.
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:, **rest) = [a, b, rest]
        shapeless = { a: 1 }
        shapeless[:b] = 2
        opaque = JSON.parse("{}")
        assert_type("Dynamic[top]", target(**shapeless))
        assert_type("Dynamic[top]", target(**opaque))
      RUBY
    end

    it "keeps the pre-#1125 answer for a hash whose every key a named parameter consumes" do
      # `rest` holds nothing this call site can name, so it keeps the pre-#1125 `Dynamic[top]` — the
      # literal form's existing binding, which this change MUST NOT move.
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:, **rest) = [a, b, rest]
        t = target(a: 1, b: 2)
        assert_type("[1, 2, Dynamic[top]]", t)
      RUBY
    end

    it "declines a mixed keyword hash" do
      # `target(a: 1, **h)` merges a literal pair with a splatted shape; that merge is not attempted.
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:) = [a, b]
        h = { b: 2 }
        assert_type("Dynamic[top]", target(a: 1, **h))
      RUBY
    end
  end

  describe "**rest collection" do
    it "collects the keys no named parameter consumed, with their value types" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:, **rest) = rest
        h = { a: 1, b: 2, c: "z", d: 3 }
        assert_type("{ c: \\"z\\", d: 3 }", target(**h))
      RUBY
    end

    it "collects every key of a keyword-rest-only method" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(**rest) = rest
        h = { a: 1, b: "z" }
        assert_type("{ a: 1, b: \\"z\\" }", target(**h))
      RUBY
    end

    it "collects the same leftovers from the literal keyword form" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:, **rest) = rest
        assert_type("{ c: \\"z\\" }", target(a: 1, b: 2, c: "z"))
      RUBY
    end
  end

  describe "`...` forwarding" do
    it "binds the callee's parameters from the forwarding method's own call site" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a, b) = [a, b]
        def forward(...) = target(...)
        t = forward(1, 2)
        assert_type("[1, 2]", t)
      RUBY
    end

    it "forwards keyword arguments" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:) = [a, b]
        def forward(...) = target(...)
        t = forward(a: 1, b: 2)
        assert_type("[1, 2]", t)
      RUBY
    end

    it "threads across a chain of forwarding methods" do
      # RECORDED DECISION (issue #1125): `...` is threaded ACROSS a chain, not one level. Each frame
      # installs its own call-site argument list, so `forward -> middle -> target` re-expands at every
      # hop, bounded by the ordinary ADR-55 recursion guard / ADR-84 return memo.
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a, b) = [a, b]
        def middle(...) = target(...)
        def forward(...) = middle(...)
        t = forward(1, 2)
        assert_type("[1, 2]", t)
      RUBY
    end

    it "excludes the positionals the forwarding method's own named parameters consumed" do
      # `...` beside a leading positional forwards only the TAIL; `a` is not re-supplied.
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a, b, c) = [a, b, c]
        def forward(a, ...) = target(a, ...)
        t = forward(1, 2, 3)
        assert_type("[1, 2, 3]", t)
      RUBY
    end

    it "forwards a double-splatted hash shape" do
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a:, b:) = [a, b]
        def forward(...) = target(...)
        h = { a: 1, b: 2 }
        t = forward(**h)
        assert_type("[1, 2]", t)
      RUBY
    end
  end

  describe "the declines recorded while in the call-site binder" do
    it "declines a bare *args forwarding (a SplatNode has no binder-visible expansion)" do
      # RECORDED DECISION (issue #1125): `target(*args)` types the splat node `Dynamic[top]`, so the
      # callee's required positionals cannot be counted. Expanding a `Tuple`-typed rest into positional
      # slots is a positional-correspondence slice of its own and is NOT part of this change.
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a, b) = [a, b]
        def forward(*args) = target(*args)
        assert_type("Dynamic[top]", forward(1, 2))
      RUBY
    end

    it "declines &blk forwarding (a block parameter is bound Dynamic by design)" do
      # RECORDED DECISION (issue #1125): the binder binds `&blk` to `Dynamic[top]`, and the frame's
      # `yield` type names the frame's own block, not a `&blk` local's Proc. The positional arguments
      # around it still bind.
      expect_binds(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def target(a, &blk) = [a, blk.call]
        def forward(a, &blk) = target(a, &blk)
        t = forward(1) { 2 }
        assert_type("[1, Dynamic[top]]", t)
      RUBY
    end
  end

  it "reports nothing on a correct program that reads the bound parameters and the collected rest" do
    # The acceptance's "no new diagnostic on correct code" statement. Two structural reasons it holds
    # rather than merely happening to: a callee's call-site-bound parameter types are LOWER BOUNDS that
    # the negative rules do not read (`def f(x) = x.no_such_method_here` reports nothing for a bound
    # `x`, keyword or positional alike), and the callee's return flows to the caller with exactly the
    # precision the literal keyword form already produces — pinned by the equivalence example below.
    result = analyze(<<~RUBY)
      def render(count:, label:, **rest)
        "\#{count}:\#{label}:\#{rest.size}"
      end

      opts = { count: 2, label: "x", extra: 1 }
      render(**opts)
    RUBY

    expect(result.diagnostics).to be_empty
  end

  it "reports exactly what the literal keyword form reports for the same callee" do
    # `f(**h)` MUST be indistinguishable from `f(a: 1, b: 2)` — the acceptance's own framing. The
    # fixture's return IS misused, so both arms report and the comparison is live rather than a vacuous
    # "both are silent": the change adds the literal form's diagnostics and nothing else.
    splatted = all_diagnostics(<<~RUBY)
      def pair(a:, b:) = [a, b]
      h = { a: 1, b: 2 }
      t = pair(**h)
      t.no_such_method_here
    RUBY
    literal = all_diagnostics(<<~RUBY)
      def pair(a:, b:) = [a, b]
      t = pair(a: 1, b: 2)
      t.no_such_method_here
    RUBY

    expect(splatted).not_to be_empty
    expect(splatted).to eq(literal)
  end
end
