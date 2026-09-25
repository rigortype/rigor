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

    # The surviving path of `if P then BODY else raise end` is BODY, so the post-scope must carry BODY's assignments
    # forward — not the bare predicate narrowing, which would leave them unbound. Mirrors the case/when `drops a
    # terminating else` rule.
    it "carries a then-body assignment past a terminating else (no nil-injection)" do
      _, post = evaluate(<<~RUBY)
        if cond
          x = 1
        else
          raise ArgumentError
        end
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "carries an unless-body assignment past a terminating else" do
      _, post = evaluate(<<~RUBY)
        unless cond
          x = 1
        else
          raise ArgumentError
        end
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    # Regression — liquid v5.x sweep, Event 3. The inner `elsif … else raise` previously returned the bare truthy
    # narrowing (with `x` unbound), so the OUTER if's join nil-injected `x` into a spurious `… | nil`. Every reachable
    # path assigns `x` (the else raises), so the post-scope must bind `x` without nil.
    it "binds a local across an if/elsif/else-raise chain without nil-injection" do
      _, post = evaluate(<<~RUBY)
        if a
          x = 1
        elsif b
          x = 2
        else
          raise ArgumentError
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2)
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

    it "drops a terminating else from the join so names bound in every when stay non-nil" do
      _, post = evaluate(<<~RUBY)
        case kind
        when 1 then x = "a"
        when 2 then x = "b"
        else raise ArgumentError
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly("a", "b")
    end

    it "drops a terminating when from the join" do
      _, post = evaluate(<<~RUBY)
        case kind
        when 1 then raise ArgumentError
        when 2 then x = "b"
        else x = "c"
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly("b", "c")
    end

    it "still nil-injects when a live else omits the name" do
      _, post = evaluate(<<~RUBY)
        case kind
        when 1 then x = "a"
        else 0
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly("a", nil)
    end
  end

  describe "safe-navigation truthy narrowing" do
    it "narrows a safe-nav receiver non-nil in the `&&` right operand" do
      type, _post = evaluate(<<~RUBY)
        v = rand < 0.5 ? "[x]" : nil
        if v&.start_with?("[") && v.end_with?("]")
          v
        end
      RUBY
      # The then-branch sees `v` narrowed to non-nil (`"[x]"`); the if-as-a-whole unions in the falsey `nil`. The
      # discriminator is that the then-branch value is NOT nilable — without the safe-nav narrowing `v.end_with?` would
      # have fired possible-nil and `v` inside would stay `"[x]" | nil`.
      expect(type.members.map(&:value)).to contain_exactly("[x]", nil)
    end

    it "narrows a bare safe-nav truthy edge" do
      type, _post = evaluate(<<~RUBY)
        v = rand < 0.5 ? "[x]" : nil
        if v&.length
          v.upcase
        end
      RUBY
      # `v.upcase` runs on a non-nil receiver and constant-folds to `"[X]"`; the falsey branch unions `nil`. Without the
      # safe-nav narrowing `v` would stay nilable and `upcase` could not fold.
      expect(type.members.map(&:value)).to contain_exactly("[X]", nil)
    end
  end

  describe "RSpec matcher narrowing (`expect(x)...`, v0.0.3)" do
    # The AST-shape-matched fallback: `expect(<local>)` followed by `not_to`/`to_not(be_nil)` or
    # `to(be_a/be_kind_of/be_an_instance_of/be_instance_of(C))` narrows the named local downstream. No RBS for RSpec
    # is required — the shape is recognised purely from the call nodes.
    it "narrows a local away from NilClass after `not_to be_nil`" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : nil
        expect(x).not_to be_nil
        x
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.nominal_of("Array"))
    end

    it "narrows a local away from NilClass after `to_not be_nil`" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : nil
        expect(x).to_not be_nil
        x
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.nominal_of("Array"))
    end

    it "does NOT narrow when `be_nil` carries a stray argument (defensive arity guard)" do
      # `be_nil` takes no arguments; Prism only allocates an `ArgumentsNode` when there is at least one argument
      # (`be_nil()` and bare `be_nil` both parse with `arguments: nil`), so `matcher.arguments.arguments.empty?`
      # is reachable ONLY when the matcher is (mis)written with a stray argument like `be_nil(1)`. This proves the
      # arity guard is live: without it, `not_to be_nil(1)` would incorrectly narrow `x` away from nil.
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : nil
        expect(x).not_to be_nil(1)
        x
      RUBY
      expect(post.local(:x)).to eq(
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.nominal_of("Array"), Rigor::Type::Combinator.constant_of(nil)
        )
      )
    end

    it "narrows a local to the named class after `to be_a(C)`" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : "str"
        expect(x).to be_a(Array)
        x
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.nominal_of("Array"))
    end

    it "narrows a local to the named class after `to be_kind_of(C)`" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : "str"
        expect(x).to be_kind_of(Array)
        x
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.nominal_of("Array"))
    end

    it "narrows a local to the named class after `to be_an_instance_of(C)` (exact)" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : "str"
        expect(x).to be_an_instance_of(Array)
        x
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.nominal_of("Array"))
    end

    it "narrows a local to the named class after `to be_instance_of(C)` (exact)" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : "str"
        expect(x).to be_instance_of(Array)
        x
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.nominal_of("Array"))
    end

    it "leaves the local's type unchanged for an unrecognised matcher (`eq`)" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : "str"
        expect(x).to eq("str")
        x
      RUBY
      expect(post.local(:x).members.map { |m| m.respond_to?(:class_name) ? m.class_name : m.value })
        .to contain_exactly("Array", "str")
    end

    it "leaves the local's type unchanged when the `expect(...)` target is not a bare local" do
      _, post = evaluate(<<~RUBY)
        x = rand < 0.5 ? Array.new : "str"
        expect(x.itself).to be_a(Array)
        x
      RUBY
      expect(post.local(:x).members.map { |m| m.respond_to?(:class_name) ? m.class_name : m.value })
        .to contain_exactly("Array", "str")
    end
  end

  describe "loop-exit predicate-assignment narrowing" do
    it "narrows an `until x = expr` target non-nil after the loop" do
      _, post = evaluate(<<~RUBY)
        until line = (rand < 0.5 ? "x" : nil)
          nil
        end
        line
      RUBY
      expect(post.local(:line)).to eq(Rigor::Type::Combinator.constant_of("x"))
    end

    it "narrows a `while x = expr` target to nil after the loop" do
      _, post = evaluate(<<~RUBY)
        while value = (rand < 0.5 ? "y" : nil)
          nil
        end
        value
      RUBY
      expect(post.local(:value)).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    it "leaves the target nilable when the body can break" do
      _, post = evaluate(<<~RUBY)
        until line = (rand < 0.5 ? "x" : nil)
          break
        end
        line
      RUBY
      expect(post.local(:line).members.map(&:value)).to contain_exactly("x", nil)
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

    # When a rescue arm unconditionally exits (`return`, `next`, `break`, `raise`, `throw`, `exit`, `abort`, `fail`),
    # control cannot reach the post-begin scope via that arm, so it contributes neither a value-fragment nor a
    # scope-binding to the join. The primary body's bindings survive without nil-injection from the (unreachable) rescue
    # path.
    it "drops a rescue arm whose body returns from the post-begin scope" do
      type, post = evaluate(<<~RUBY)
        x = begin
          list = [1, 2, 3]
          list
        rescue NotImplementedError
          return true
        end
        x.size
      RUBY
      # `list` survives without being widened by the (unreachable) rescue arm; `x` is the primary body's value type
      # (Array<Integer>-shaped), so `.size` resolves cleanly.
      expect(post.local(:list)).to be_a(Rigor::Type::Tuple)
      expect(type).to be_a(Rigor::Type::Constant)
    end

    it "drops a rescue arm whose body raises" do
      _, post = evaluate(<<~RUBY)
        begin
          list = [1, 2, 3]
        rescue StandardError
          raise "bail"
        end
        list
      RUBY
      # `list` remains the primary-body Tuple — the rescue arm would have raised, never bound `list`, but its scope is
      # excluded so no nil-injection occurs.
      expect(post.local(:list)).to be_a(Rigor::Type::Tuple)
    end

    it "still joins rescue arms whose bodies do not exit" do
      _, post = evaluate(<<~RUBY)
        begin
          x = 1
        rescue StandardError
          x = 2
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2)
    end

    it "joins surviving rescue arms when only some exit (mixed chain)" do
      _, post = evaluate(<<~RUBY)
        begin
          x = 1
        rescue TypeError
          x = 2
        rescue StandardError
          return
        end
      RUBY
      # The StandardError arm exits, so it contributes nothing; the TypeError arm survives and joins with the primary
      # body. The post-scope's `x` is exactly { 1, 2 } — NOT widened by the exiting arm.
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2)
    end
  end

  describe "begin/rescue/retry (retry-edge widening)" do
    # B2.1: when a rescue arm contains `retry` AND rebinds a local across the retry edge, the primary body observes the
    # rebound local widened to its Nominal envelope (not the pre-retry Constant) because control can re-enter the
    # primary body via that rescue arm. Without the widening, `tries += 1` inside the primary body would keep folding
    # from `Constant[0]` on every notional retry pass instead of reflecting that `tries` can already be a live Integer
    # by the time the primary body re-runs.

    # The binding of `name` on entry to every `node_class` node, last visit winning as in `ScopeIndexer`, so the
    # retry pass's re-evaluation overwrites the first pass's entry.
    def entry_bindings(source, node_class, name, base_scope: scope)
      entries = {}.compare_by_identity
      on_enter = ->(node, s) { entries[node] = s.local(name) || s.ivar(name) if node.is_a?(node_class) }
      described_class.new(scope: base_scope, on_enter: on_enter).evaluate(parse_program(source))
      entries.values
    end

    let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:literals) { ->(*values) { Rigor::Type::Combinator.union(*values.map { Rigor::Type::Combinator.constant_of(it) }) } }

    it "widens a local rebound across a retry edge to its Nominal envelope" do
      type, post = evaluate(<<~RUBY)
        tries = 0
        begin
          tries += 1
        rescue
          tries += 1
          retry
        end
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(post.local(:tries)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "widens an ivar rebound across a retry edge to its Nominal envelope" do
      type, post = evaluate(<<~RUBY)
        @tries = 0
        begin
          @tries += 1
        rescue
          @tries += 1
          retry
        end
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(post.ivar(:@tries)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "carries a local introduced only inside the retrying rescue arm, with its first-entry nil" do
      # `y` has no pre-existing binding in the entry scope (the `current.nil?` branch of `retry_widened_type`): the
      # retry edge still carries it rather than leaving it untouched, because the arm's own rebind cycles back through
      # the primary body on retry. A body that never raises leaves `y` nil, and the exit sees only the primary path, so
      # `nil` rides the edge too.
      _type, post = evaluate(<<~RUBY)
        begin
          1
        rescue
          y = 1
          retry
        end
      RUBY
      # One re-evaluation puts nothing new on the edge, so the literal holds.
      expect(post.local(:y)).to eq(literals.call(nil, 1))
    end

    it "does not join an arm that ends in retry into the exit" do
      # The arm leaves back into the primary body, never past the `begin`, so the widened `st` it holds must not reach
      # the exit: the body always ends by resetting it to `:ok`.
      source = <<~RUBY
        st = :ok
        begin
          st = :retrying
          ping
          st = :ok
        rescue IOError
          retry
        end
        st
      RUBY
      expect(evaluate(source).first).to eq(Rigor::Type::Combinator.constant_of(:ok))
    end

    it "does NOT widen when the rescue arm does not contain retry" do
      # Guards `arm_contains_retry?` / `widen_entry_for_retry`'s nil return: an ordinary (non-retrying) rescue arm
      # rebinding the same local must keep the precise Constant union produced by the un-widened join, not a Nominal
      # envelope.
      _type, post = evaluate(<<~RUBY)
        tries = 0
        begin
          tries += 1
        rescue
          tries = 99
        end
      RUBY
      expect(post.local(:tries).members.map(&:value)).to contain_exactly(1, 99)
    end

    it "re-evaluates the else-clause under the widened retry entry" do
      # Exercises eval_begin_primary_under's else-clause branch (the primary body ran, then else replaces its value)
      # under a widened entry produced by a sibling retry arm.
      type, post = evaluate(<<~RUBY)
        tries = 0
        begin
          tries += 1
        rescue
          tries += 1
          retry
        else
          tries
        end
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(post.local(:tries)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "re-evaluates the ensure-clause's scope on top of the widened retry join" do
      _type, post = evaluate(<<~RUBY)
        tries = 0
        begin
          tries += 1
        rescue
          tries += 1
          retry
        ensure
          done = true
        end
      RUBY
      expect(post.local(:tries)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(post.local(:done)).to eq(Rigor::Type::Combinator.constant_of(true))
    end

    it "re-evaluates every arm of a multi-rescue chain under the widened entry" do
      # Only the first arm retries, but widen_entry_for_retry widens the shared entry scope once, and BOTH
      # collect_rescue_chain_results calls (pre- and post-widening) walk the full rescue_clause chain — the second
      # (non-retrying) arm's fresh evaluation must also be visible in the final union.
      type, post = evaluate(<<~RUBY)
        tries = 0
        begin
          tries += 1
        rescue TypeError
          tries += 1
          retry
        rescue StandardError
          tries = "boom"
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to contain_exactly(
        Rigor::Type::Combinator.constant_of("boom"),
        Rigor::Type::Combinator.nominal_of("Integer")
      )
      expect(post.local(:tries)).to eq(type)
    end

    it "widens a backoff the retrying arm grows before a guard that folds" do
      # `delay < 8` folds to true, so the arm's fall-through past the guard is dead and holds `delay` as `bot`. The
      # scope at the `retry` is the one that carries `delay *= 2` back into the body.
      source = <<~RUBY
        delay = 0.5
        begin
          work
        rescue StandardError
          delay *= 2
          retry if delay < 8
        end
      RUBY
      expect(entry_bindings(source, Prism::IfNode, :delay)).to eq([Rigor::Type::Combinator.nominal_of("Float")])
    end

    it "does not widen what a retry guard only narrows" do
      # The scope at `retry` holds `m: :fast`, which the entry's `:fast | :slow` accepts.
      source = <<~RUBY
        m = pick ? :fast : :slow
        begin
          ping
        rescue IOError
          retry if m == :fast
        end
        m
      RUBY
      expect(evaluate(source).first).to eq(
        Rigor::Type::Combinator.union(*%i[fast slow].map { Rigor::Type::Combinator.constant_of(it) })
      )
    end

    it "carries a nil-seeded backoff across the retry its guard takes" do
      # The arm's fall-through past `retry if wait < 5` is dead, and `wait` there is `bot`; only the scope at the
      # `retry` holds the `0.5` the arm assigned, so the body's `if wait` and the arm's `wait < 5` stop folding.
      source = <<~RUBY
        wait = nil
        begin
          sleep(wait) if wait
          work
        rescue IOError
          wait = wait ? wait * 2 : 0.5
          retry if wait < 5
          raise
        end
      RUBY
      nil_or_float = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(nil), Rigor::Type::Combinator.nominal_of("Float")
      )
      # The body's `if wait`, the arm's ternary, then the guard, which reads the ternary's `0.5 | Float`.
      expect(entry_bindings(source, Prism::IfNode, :wait)).to eq(
        [nil_or_float, nil_or_float,
         Rigor::Type::Combinator.union(Rigor::Type::Combinator.constant_of(0.5), Rigor::Type::Combinator.nominal_of("Float"))]
      )
    end

    it "follows only the retries that target this begin" do
      # The inner `rescue`'s `retry` re-runs `cleanup`, and so does a rescue modifier's (Ruby 4.0.5 retries the
      # modifier's own expression); the one under the inner `begin`'s body, outside its `rescue`, re-enters the outer
      # `begin`. Only that last shape widens the outer counter.
      inner_rescue = <<~RUBY
        tries = 0
        begin
          tries += 1
          raise "boom" if tries < 3
        rescue
          begin
            cleanup
          rescue
            retry
          end
        end
      RUBY
      inner_body = inner_rescue.sub("    cleanup\n  rescue\n    retry\n", "    retry\n  ensure\n    cleanup\n")
      modifier = inner_rescue.sub("  begin
    cleanup
  rescue
    retry
  end
", "  cleanup rescue retry
")
      expect(entry_bindings(inner_rescue, Prism::IfNode, :tries)).to eq([Rigor::Type::Combinator.constant_of(1)])
      expect(entry_bindings(modifier, Prism::IfNode, :tries)).to eq([Rigor::Type::Combinator.constant_of(1)])
      expect(entry_bindings(inner_body, Prism::IfNode, :tries)).to eq([integer])
    end

    it "does not join an arm that can only retry or raise into the exit" do
      # Each arm types `bot`, so none falls through past the `begin`, whatever shape its `retry` takes.
      source = <<~RUBY
        st = :ok
        tries = 0
        begin
          st = :retrying
          ping
          st = :ok
        rescue IOError
          tries += 1
          ARM
        end
        st
      RUBY
      arms = ["tries < 3 ? retry : raise", "if tries < 3 then retry else raise end",
              "case tries when 0..2 then retry else raise end", "begin\n retry\nensure\n log\nend"]
      arms.each do |arm|
        expect(evaluate(source.sub("ARM", arm)).first).to eq(Rigor::Type::Combinator.constant_of(:ok)), arm
      end
    end

    it "carries what an ensure runs on the way out to a retry" do
      # The inner `ensure` runs before the `retry` re-enters, so its `tries += 1` crosses the edge; the scope at the
      # `retry` itself predates it, and only the arm's post-scope holds it.
      source = <<~RUBY
        tries = 0
        begin
          raise "flaky" if tries < 2
        rescue
          begin
            retry
          ensure
            tries += 1
          end
        end
      RUBY
      expect(entry_bindings(source, Prism::IfNode, :tries)).to eq([integer])
    end

    it "carries a rebind made before a retry the evaluator only types" do
      # `log(...)`'s argument holds no write, `next` or `break`, so the evaluator types it whole and never reaches its
      # `retry`; the arm's post-scope still carries `tries += 1`.
      source = <<~RUBY
        tries = 0
        begin
          warn "attempt" if work
        rescue
          tries += 1
          log(tries < 5 ? retry : :gave_up)
        end
      RUBY
      expect(entry_bindings(source, Prism::IfNode, :tries).first).to eq(integer)
    end

    it "leaves a rescue modifier's retry out of the begin's exit narrowing" do
      # A modifier's `retry` re-runs its own expression, and nothing widens across that edge, so its rescue path must
      # keep joining the result: `attempts == 1` is not known after it.
      source = <<~RUBY
        attempts = 0
        v = work(attempts += 1) rescue retry
        log("first try") if attempts == 1
      RUBY
      expect(entry_bindings(source, Prism::IfNode, :attempts)).to eq([literals.call(0, 1)])
    end

    it "widens a precise collection an arm rebinds to one holding untyped elements" do
      # `Array[Integer]` gradually accepts `[fetch]`, but keeping it would claim the elements are still Integers.
      source = <<~RUBY
        xs = Array.new(size, 0)
        begin
          warn "attempt" if work
        rescue
          xs = [fetch]
          retry
        end
      RUBY
      env_scope = Rigor::Scope.empty(environment: Rigor::Environment.default)
      expect(entry_bindings(source, Prism::IfNode, :xs, base_scope: env_scope).first)
        .not_to eq(Rigor::Type::Combinator.nominal_of("Array", type_args: [integer]))
    end

    # The primary body can raise after any prefix of itself, so what it rebinds before raising is what the rescue arm
    # sees and what the retry re-enters with — whether or not the arm rebinds anything itself.
    context "when the primary body rebinds before a retried raise" do
      it "widens the counter the retried predicate reads" do
        source = <<~RUBY
          tries = 0
          begin
            tries += 1
            raise "boom" if tries < 3
          rescue
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :tries)).to eq([integer])
      end

      it "widens an ivar counter the same way" do
        source = <<~RUBY
          @tries = 0
          begin
            @tries += 1
            raise "boom" if @tries < 3
          rescue
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :@tries)).to eq([integer])
      end

      it "widens a rebind on a raising branch for the rescue arm's guard" do
        # `eval_if` drops the raising branch's scope from the fall-through, so only a scope observed at the raise
        # carries `tries += 1` — the arm's `tries < 3` otherwise folds from the entry's `0`. The guard is not
        # `retry if tries < 3`: narrowing the counter there changes the arm's post-scope, which the arm's own
        # rebind widening already picks up.
        source = <<~RUBY
          tries = 0
          begin
            if work
              tries += 1
              raise "boom"
            end
          rescue
            warn "retrying" if tries < 3
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :tries).last).to eq(integer)
      end

      it "keeps every value the primary body rebinds a local to before raising" do
        # The raise can follow either rebind, so the arm sees `x` as `"a"` as well as the `:b` the body exits with.
        source = <<~RUBY
          x = 0
          begin
            x = "a"
            work
            x = :b
            work
          rescue
            warn "retrying" if work
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :x)).to eq([literals.call(0, "a", :b)])
      end

      it "does not widen a binding the primary body only narrows" do
        # Inside `if m == :fast` the scope holds `m: :fast`, which the entry's `:fast | :slow` already accepts. Widening
        # it would read `m` as `Symbol` after the `begin` and break a declared `:fast | :slow` return.
        source = <<~RUBY
          m = pick ? :fast : :slow
          begin
            log if m == :fast
            ping
          rescue IOError
            retry
          end
          m
        RUBY
        expect(evaluate(source).first).to eq(
          Rigor::Type::Combinator.union(*%i[fast slow].map { Rigor::Type::Combinator.constant_of(it) })
        )
      end

      it "widens a rebind to an untyped value, which the entry's binding cannot vouch for" do
        source = <<~RUBY
          tries = 0
          begin
            warn "attempt" if work
            tries = fetch_tries
          rescue
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :tries).first).not_to eq(Rigor::Type::Combinator.constant_of(0))
      end

      it "keeps nil, true and false as constants on the retry edge" do
        # `Nominal[FalseClass] | Nominal[TrueClass]` is not accepted where `bool` is declared, nor `Nominal[NilClass]`
        # where `String?` is.
        source = <<~RUBY
          ok = false
          err = nil
          begin
            connect
            ok = true
            err = "none"
          rescue IOError
            warn "retrying" if work
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :ok)).to eq([literals.call(false, true)])
        expect(entry_bindings(source, Prism::IfNode, :err)).to eq([literals.call(nil, "none")])
      end

      it "keeps every retrying arm's rebind" do
        source = <<~RUBY
          x = 0
          begin
            warn "attempt" if work
          rescue TypeError
            x = "a"
            retry
          rescue ArgumentError
            x = :b
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :x)).to eq([literals.call(0, "a", :b)])
      end

      it "leaves a local both the body and a retrying arm assign unbound on the edge" do
        # Carrying the arm's `conn = nil` would fold its `if conn` on the next attempt, when the body has reassigned it.
        source = <<~RUBY
          begin
            conn = open_conn
            conn.query
          rescue IOError
            conn.close if conn
            conn = nil
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :conn)).to eq([nil])
      end

      it "widens a counter written inside the raise's own arguments" do
        # The write lands only in the raising call's post-scope, on the branch `eval_if` drops.
        source = <<~RUBY
          tries = 0
          begin
            raise ArgumentError, (tries += 1).to_s if work
          rescue ArgumentError
            warn "retrying" if tries < 3
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :tries).last).to eq(integer)
      end

      it "keeps a literal state variable literal when one re-evaluation closes the edge" do
        # A live arm (`retry if flaky?; log`) joins the exit, and a conditional rebind reaches it, so the retry edge's
        # entry shows past the `begin`: it must still be `:ok | :retrying`, not `Symbol`.
        state = <<~RUBY
          st = :ok
          begin
            st = :retrying
            ping
            st = :ok
          rescue IOError
            retry if flaky?
            log
          end
          st
        RUBY
        mode = <<~RUBY
          mode = :fast
          begin
            mode = :slow if degraded?
            ping
          rescue IOError
            retry
          end
          mode
        RUBY
        expect(evaluate(state).first).to eq(literals.call(:ok, :retrying))
        expect(evaluate(mode).first).to eq(literals.call(:fast, :slow))
      end

      it "ignores a block parameter that shadows the counter" do
        source = <<~RUBY
          line = 0
          begin
            %w[a b].each { |line| line.upcase }
            line += 1
            raise "boom" if line < 3
          rescue
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :line)).to eq([integer])
      end

      it "leaves a local the primary body introduces unbound on the retry edge" do
        # An unbound local reads as `Dynamic[top]`, which is what it is on the first entry. Binding the body's type
        # instead would make the arm's `if conn` always truthy, when `conn` is nil whenever the assignment raised.
        source = <<~RUBY
          begin
            conn = Object.new
            conn.frozen?
          rescue
            conn.freeze if conn
            retry
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :conn)).to eq([nil])
      end

      it "does NOT widen what the else-clause rebinds" do
        # An exception the else-clause raises is not rescued by this `begin`, so no retry follows it.
        source = <<~RUBY
          tries = 0
          begin
            warn "attempt" if work
          rescue
            retry
          else
            tries = 5
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :tries)).to eq([Rigor::Type::Combinator.constant_of(0)])
      end

      it "keeps the counter folded when no arm retries" do
        source = <<~RUBY
          tries = 0
          begin
            tries += 1
            raise "boom" if tries < 3
          rescue
            nil
          end
        RUBY
        expect(entry_bindings(source, Prism::IfNode, :tries)).to eq([Rigor::Type::Combinator.constant_of(1)])
      end
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

    it "for-loop binds the index in the post-loop scope (nil-injected)" do
      type, post = evaluate(<<~RUBY)
        for i in [1, 2, 3]
        end
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
      # `i` is bound only inside the body, so the no-iteration join path nil-injects it into the post-loop scope. The
      # element type comes from the Tuple[1, 2, 3] carrier.
      i_type = post.local(:i)
      members = i_type.members.map { |m| m.is_a?(Rigor::Type::Constant) ? m.value : m }
      expect(members).to include(1, 2, 3, nil)
    end

    it "for-loop with multi-target index destructures a tuple element" do
      _, post = evaluate(<<~RUBY)
        for a, b in [[1, 2]]
        end
      RUBY
      # `[[1, 2]]` is `Tuple[Tuple[1, 2]]`; the per-iteration element is `Tuple[1, 2]`, which the multi-target binder
      # splits into `a: 1` and `b: 2`. The names are nil-injected through the zero-iteration join.
      expect(post.local(:a).members).to include(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:b).members).to include(Rigor::Type::Combinator.constant_of(2))
    end

    it "for-loop falls back to untyped when collection has no known element type" do
      _, post = evaluate(<<~RUBY)
        for x in unknown
        end
      RUBY
      expect(post.local(:x)).not_to be_nil
    end

    it "for-loop over an Integer Range literal binds the index to Integer" do
      _, post = evaluate(<<~RUBY)
        for i in (1..10)
        end
      RUBY
      nominal = post.local(:i).members.grep(Rigor::Type::Nominal)
      expect(nominal.map(&:class_name)).to contain_exactly("Integer")
    end

    it "for-loop over a Type::IntegerRange-narrowed collection binds the index to Integer" do
      # Distinct from the literal-Range case above: `case n; when 1..10` narrows `n` itself to a `Type::IntegerRange`
      # carrier (not a `Constant<Range>`), so `for i in n` exercises `collection_element_type`'s `Type::IntegerRange`
      # branch rather than `constant_element_type`'s `Range` branch.
      _, post = evaluate(<<~RUBY)
        n = rand(100)
        case n
        when 1..10
          for i in n
          end
        end
      RUBY
      nominal = post.local(:i).members.grep(Rigor::Type::Nominal)
      expect(nominal.map(&:class_name)).to contain_exactly("Integer")
    end

    it "for-loop over a String Range literal binds the index to String" do
      _, post = evaluate(<<~RUBY)
        for ch in ("a".."z")
        end
      RUBY
      nominal = post.local(:ch).members.grep(Rigor::Type::Nominal)
      expect(nominal.map(&:class_name)).to contain_exactly("String")
    end

    it "for-loop over a Hash literal destructures into key / value via RBS dispatch" do
      env = Rigor::Environment.for_project
      base = Rigor::Scope.empty(environment: env)
      _, post = evaluate(<<~RUBY, base_scope: base)
        for k, v in { a: 1, b: 2 }
        end
      RUBY
      # `Hash#each` yields `[K, V]`; the multi-target binder splits that into per-iteration `k` and `v` bindings,
      # nil-injected through the zero-iteration join.
      k_members = post.local(:k).members.map { |m| m.is_a?(Rigor::Type::Constant) ? m.value : m }
      v_members = post.local(:v).members.map { |m| m.is_a?(Rigor::Type::Constant) ? m.value : m }
      expect(k_members).to include(:a, :b, nil)
      expect(v_members).to include(1, 2, nil)
    end

    it "for-loop body-locals leak into the surrounding scope" do
      _, post = evaluate(<<~RUBY)
        for i in [1, 2, 3]
          y = "hi"
        end
      RUBY
      # Unlike `each {}`, `for` does not introduce a new variable scope: writes inside the body are observable after the
      # loop.
      expect(post.local(:y).members.map(&:value)).to contain_exactly("hi", nil)
    end

    # A `for` index that is an index target (`for h[:a] in xs`) stores each element through `[]=` on its receiver at
    # the top of every iteration, so it widens the receiver exactly as the body store `h[:a] = x` of the same element
    # does — otherwise the literal survives and a later `h[:a] == 0` folds on its stale `0`.
    it "for-loop with an index-target index widens the receiver the way a body `[]=` store of the element does" do
      _, index = evaluate("h = { a: 0 }\nfor h[:a] in [1, 2]; end")
      _, body = evaluate("h = { a: 0 }\nfor x in [1, 2]; h[:a] = x; end")
      expect(index.local(:h)).to eq(body.local(:h))
      expect(index.local(:h).members).to include(a_kind_of(Rigor::Type::Nominal))
    end

    it "for-loop with an index-target index joins the element itself into a seed that admits it" do
      # An empty literal carries no class set to contradict the stored `Integer`, so the join keeps it.
      _, index = evaluate("h = {}\nfor h[:a] in [1, 2]; end")
      _, body = evaluate("h = {}\nfor x in [1, 2]; h[:a] = x; end")
      expect(index.local(:h)).to eq(body.local(:h))
    end

    # The store runs before the body, on every iteration, so the body reads the widened receiver too.
    it "for-loop body reads the receiver an index-target index widened" do
      _, index = evaluate("h = { a: 0 }\nfor h[:a] in [1, 2]\n  seen = h\nend")
      _, body = evaluate("h = { a: 0 }\nfor x in [1, 2]\n  h[:a] = x\n  seen = h\nend")
      expect(index.local(:seen)).to eq(body.local(:seen))
      expect(index.local(:seen).members).not_to include(a_kind_of(Rigor::Type::HashShape))
    end

    it "for-loop with a multi-target index widens an index target's receiver with the slot it stores" do
      _, index = evaluate("h = { a: 0 }\nfor h[:a], w in [[1, 2]]; end")
      _, body = evaluate("h = { a: 0 }\nfor x, w in [[1, 2]]; h[:a] = x; end")
      expect(index.local(:h)).to eq(body.local(:h))
      expect(index.local(:w)).to eq(body.local(:w))
    end

    it "for-loop with an index-target index leaves a collection it does not name at its literal shape" do
      _, single = evaluate("h = { a: 0 }\ng = {}\nfor g[:a] in [1, 2]; end")
      _, multi = evaluate("h = { a: 0 }\ng = {}\nfor g[:a], w in [[1, 2]]; end")
      expect(single.local(:h)).to be_a(Rigor::Type::HashShape)
      expect(multi.local(:h)).to be_a(Rigor::Type::HashShape)
      expect(single.local(:g)).not_to be_a(Rigor::Type::HashShape)
      expect(multi.local(:g)).not_to be_a(Rigor::Type::HashShape)
    end

    # The store overwrites the slot a `receiver[key] ||= default` narrowed, so it drops that narrowing as the body
    # store does — otherwise `h[:e]` keeps reading the `||=` default. A store into another slot keeps it.
    it "for-loop with an index-target index drops the stored slot's `||=` narrowing and keeps another slot's" do
      seed = "h = { e: nil }\nh[:e] ||= 0\n"
      _, index = evaluate("#{seed}for h[:e] in [1, 2]; end\nv = h[:e]")
      _, body = evaluate("#{seed}for x in [1, 2]; h[:e] = x; end\nv = h[:e]")
      _, other = evaluate("#{seed}for h[:f] in [1, 2]; end\nv = h[:e]")
      expect(index.local(:v)).to eq(body.local(:v))
      expect(index.local(:v)).not_to eq(Rigor::Type::Combinator.constant_of(0))
      expect(other.local(:v)).to eq(Rigor::Type::Combinator.constant_of(0))
    end

    # `for *h[:a] in pairs` is `*h[:a] = element`: Prism gives the index as a bare `SplatNode`, not a multi-target.
    it "for-loop with a bare splat index-target index widens the receiver" do
      _, post = evaluate("h = { a: 0 }\ng = { a: 0 }\nfor *h[:a] in [[1, 2]]; end")
      expect(post.local(:h).members).to include(a_kind_of(Rigor::Type::Nominal))
      expect(post.local(:g)).to be_a(Rigor::Type::HashShape)
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
      type, _post = evaluate("(1 if rand < 0.5) || \"hi\"")
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, "hi")
    end

    # Issue #1016 — the constant short-circuit the value position always had is the statement position's too, so
    # `1 || "hi"` no longer differs between `x = 1 || "hi"` and `[1 || "hi"]`. The dead RHS still runs through the
    # evaluator, so a write inside it keeps nil-injecting.
    it "drops a dead right operand's value behind a genuine constant left operand" do
      type, post = evaluate("1 || (y = \"hi\")")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:y).members.map(&:value)).to contain_exactly("hi", nil)
    end

    # Early-return narrowing through the OR / AND seam, mirroring the `eval_if` / `eval_unless`
    # `branch_unconditionally_exits?` path. When the RHS terminates (raise / return / throw / exit / abort / fail / next
    # / break), the surviving control flow is the LHS-skipped edge alone, so the post-scope narrows the write target
    # accordingly.
    context "when the RHS unconditionally exits (early-return narrowing across or / and)" do
      let(:union_local) do
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.nominal_of("String"),
          Rigor::Type::Combinator.constant_of(nil)
        )
      end
      let(:bound_scope) { scope.with_local(:v, union_local) }

      def parse(source, locals: %i[v m])
        Prism.parse(source, scopes: [locals]).value
      end

      it "narrows the assignment target after `lhs = expr or raise`" do
        _, post = bound_scope.evaluate(parse(<<~RUBY))
          (m = v) or raise "bad"
        RUBY
        # The OR survives only when the LHS write is truthy; the nil fragment is removed from `m`.
        expect(post.local(:m)).to be_a(Rigor::Type::Nominal)
        expect(post.local(:m).class_name).to eq("String")
      end

      it "narrows after `lhs = expr or return`" do
        _, post = bound_scope.evaluate(parse(<<~RUBY))
          (m = v) or return nil
        RUBY
        expect(post.local(:m).class_name).to eq("String")
      end

      it "narrows after `lhs = expr or throw`" do
        _, post = bound_scope.evaluate(parse(<<~RUBY))
          (m = v) or throw :done
        RUBY
        expect(post.local(:m).class_name).to eq("String")
      end

      it "narrows after the high-precedence `||` form" do
        _, post = bound_scope.evaluate(parse(<<~RUBY))
          m = (v || raise("bad"))
        RUBY
        expect(post.local(:m).class_name).to eq("String")
      end

      it "narrows symmetrically for `lhs = expr and raise`" do
        _, post = bound_scope.evaluate(parse(<<~RUBY))
          (m = v) and raise "got something"
        RUBY
        # AND survives only when LHS is falsey, so `m` is the nil fragment.
        expect(post.local(:m)).to eq(Rigor::Type::Combinator.constant_of(nil))
      end

      it "produces the narrowed surviving type as the OR expression's value" do
        type, _post = bound_scope.evaluate(parse(<<~RUBY))
          (m = v) or raise "bad"
        RUBY
        # Value of the OR expression is the truthy fragment of the LHS write — String only, no nil.
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("String")
      end

      it "is unchanged when RHS does not unconditionally exit" do
        # `a || b` where neither side exits — the existing
        # join-with-nil-injection path still runs and post-scope
        # binds `m` to the union (no narrowing).
        _, post = bound_scope.with_local(:w, union_local).evaluate(parse(<<~RUBY, locals: %i[v w m]))
          (m = v) || (m = w)
        RUBY
        expect(post.local(:m)).to be_a(Rigor::Type::Union)
      end
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

      # Sanity: every recursive sub_eval threads the callback so the rvalue (`x + 2`) is recorded with `x` already
      # bound.
      x_plus_2_event = events.find { |klass, _| klass == Prism::CallNode }
      expect(x_plus_2_event).not_to be_nil
      expect(x_plus_2_event[1]).to include(:x)
    end

    it "fires for nodes whose handler is the default fallback branch" do
      events = []
      on_enter = ->(node, _scope) { events << node.class }
      ast = parse_program("foo(1)")
      described_class.new(scope: scope, on_enter: on_enter).evaluate(ast)

      # The CallNode has no statement-evaluator handler; the default branch still fires on_enter so callers (the
      # ScopeIndexer) can record its entry scope.
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

    # Build an `on_enter` callback that records the entry-scope binding for `name` whenever the evaluator visits a
    # LocalVariableReadNode for that name. Returns the events array (mutable) and the callback together.
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
      # The singleton path was consulted (no exception, the local is bound to *some* type, possibly Dynamic[Top] when
      # the RBS type is an interface alias). The structural property under test is that the local was bound at all.
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
      # The class body's children enter with the fresh empty scope (`[]`), even though the outer `x = 1` post-scope
      # contains x.
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
      # The binder's class_path is "A::B" here. Neither A nor A::B exist in core RBS, so x falls back to Dynamic[Top];
      # the structural test is just that no exception is raised.
      ast = parse_program("class A; class B; def foo(x); x; end; end; end")
      expect { described_class.new(scope: scope).evaluate(ast) }.not_to raise_error
    end

    it "walks DefNode arguments wrapped in a CallNode (ruby2_keywords / private def)" do
      observed = []
      on_enter = ->(node, s) { observed << s.self_type if node.is_a?(Prism::SelfNode) }
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Foo
          ruby2_keywords def bar(*args)
            self
          end
        end
      RUBY
      # The body of `bar` -- inside the ruby2_keywords(<DefNode>) call -- sees self as Nominal[Foo] (instance method),
      # NOT Singleton[Foo].
      expect(observed).to include(Rigor::Type::Combinator.nominal_of("Foo"))
      expect(observed).not_to include(Rigor::Type::Combinator.singleton_of("Foo"))
    end

    it "walks private/public def argument-position bodies under their instance self_type" do
      observed = []
      on_enter = ->(node, s) { observed << s.self_type if node.is_a?(Prism::SelfNode) }
      described_class.new(scope: scope, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        class Foo
          private def bar; self; end
        end
      RUBY
      expect(observed).to include(Rigor::Type::Combinator.nominal_of("Foo"))
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

    # Parse `source` with `x` and `y` pre-declared as locals so the parser produces `LocalVariableReadNode` rather than
    # implicit `CallNode` references. Tests that need a different local set MAY pass `locals:`.
    def parse_with_locals(source, locals: %i[x y])
      Prism.parse(source, scopes: [locals]).value
    end

    # Build an `on_enter` callback that records the entry-scope binding for `name` whenever the evaluator visits a
    # LocalVariableReadNode for that name. Returns the events array (mutable) and the callback together.
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

      # Predicate read sees the untouched union; the then-branch read sees x narrowed to Integer; the else-branch read
      # sees x narrowed to Constant[nil].
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

      # In `unless x` the body runs when x is falsey, the else-clause when x is truthy. The narrower swaps the two edges
      # accordingly.
      then_read, else_read = events.last(2)
      expect(then_read).to eq(Rigor::Type::Combinator.constant_of(nil))
      expect(else_read).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    # Slice 6 phase D — IntegerRange narrowing wired into IfNode.
    it "narrows `if x > 0` to positive_int / non_positive_int" do
      bound = scope.with_local(:x, Rigor::Type::Combinator.nominal_of("Integer"))
      events, on_enter = watch_local_reads(:x)
      ast = parse_with_locals(<<~RUBY)
        if x > 0
          x
        else
          x
        end
      RUBY
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)

      then_read, else_read = events.last(2)
      expect(then_read).to eq(Rigor::Type::Combinator.positive_int)
      expect(else_read).to eq(Rigor::Type::Combinator.non_positive_int)
    end

    it "intersects with an existing IntegerRange bound" do
      bound = scope.with_local(:x, Rigor::Type::Combinator.integer_range(-10, 10))
      events, on_enter = watch_local_reads(:x)
      ast = parse_with_locals(<<~RUBY)
        if x >= 5
          x
        else
          x
        end
      RUBY
      described_class.new(scope: bound, on_enter: on_enter).evaluate(ast)

      then_read, else_read = events.last(2)
      expect(then_read).to eq(Rigor::Type::Combinator.integer_range(5, 10))
      expect(else_read).to eq(Rigor::Type::Combinator.integer_range(-10, 4))
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
      # After the if, x has the union of the two narrowed branches, which collapses back to the original `Integer | nil`
      # because the two narrowings partition the union.
      expect(post.local(:x)).to eq(union_int_nil)
    end

    it "evaluates the RHS of `&&` under the LHS truthy scope" do
      # `x.succ` only resolves cleanly when `x` is narrowed to a non-nil Integer; otherwise dispatch over `Integer |
      # nil` cannot prove `NilClass` defines `succ`. The RHS therefore types as `Nominal[Integer]` only when the
      # narrower flowed `x` into the RHS scope.
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

      # The LHS read sees the unnarrowed union; we don't assert on `events[1]` because the RHS receiver is typed via
      # ExpressionTyper, which does not fire `on_enter`. The behavioural proof is in the dispatched return type below.
      expect(events.first).to eq(union_int_nil)

      type, _post = bound.evaluate(ast)
      expect(type).to be_a(Rigor::Type::Union)
      # The RHS `x.nil?` resolves on `Constant[nil]` to `Constant[true]` because `x` was narrowed to `nil` in the falsey
      # branch. The full expression unions LHS and RHS.
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

      # In the truthy branch x is narrowed to its non-falsey fragment; the read of `x` therefore returns `Integer`.
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

      # The truthy branch is unreachable because the RHS sees x narrowed to "a", then intersects that with "b".
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
      # The predicate receiver is typed by ExpressionTyper directly and is not surfaced through `on_enter`. Only the two
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
      # The else edge cannot prove "Numeric is not an Integer", so it stays conservative and preserves Nominal[Numeric].
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

    # An index target stores through `[]=` on its receiver, so it widens the receiver's literal shape and joins
    # the slot's value exactly as the plain store of the same value does — otherwise `h[:a] == 0` after
    # `h[:a], z = 1, 2` folds on the literal's stale `0`.
    it "widens an index target's receiver the way a plain `[]=` store of the slot's value does" do
      _, multi = evaluate("h = { a: 0 }\nh[:a], z = 1, 2")
      _, plain = evaluate("h = { a: 0 }\nh[:a] = 1")
      expect(multi.local(:h)).to be_a(Rigor::Type::Nominal)
      expect(multi.local(:h)).to eq(plain.local(:h))
      expect(multi.local(:z)).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "joins the slot's own value, not an untyped one, into a seed that admits it" do
      # An empty literal carries no class set to contradict the stored `Integer`, so the join keeps it.
      _, multi = evaluate("h = {}\nh[:a], z = 1, 2")
      _, plain = evaluate("h = {}\nh[:a] = 1")
      expect(multi.local(:h)).to eq(plain.local(:h))
    end

    it "widens an index target nested in a group and a splatted one with the value each slot stores" do
      _, multi = evaluate("h = { a: 0 }\na = [0]\n(h[:a], q), *a[0] = [1, 2], 3, 4")
      _, plain = evaluate("h = { a: 0 }\na = [0]\nh[:a] = 1\na[0] = [3, 4]")
      expect(multi.local(:h)).to eq(plain.local(:h))
      expect(multi.local(:a)).to eq(plain.local(:a))
      expect(multi.local(:q)).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "widens an array slot target and a splice target as the plain stores do (issue #1168)" do
      _, slot = evaluate("a = [1]\na[0], b = \"s\", 2")
      _, plain_slot = evaluate("a = [1]\na[0] = \"s\"")
      expect(slot.local(:a)).to be_a(Rigor::Type::Nominal)
      expect(slot.local(:a)).to eq(plain_slot.local(:a))

      _, splice = evaluate("a = []\na[0, 1], b = [2], 3")
      _, plain_splice = evaluate("a = []\na[0, 1] = [2]")
      expect(splice.local(:a)).to eq(plain_splice.local(:a))
    end

    it "widens after the bindings, so a target that rebinds the receiver to itself cannot restore the literal" do
      # Ruby evaluates `h` (the receiver) before assigning any target, so the store lands on the object `h` is
      # bound to afterwards. Widening before the bindings let `h`'s own binding bring `{ a: 0 }` back.
      _, post = evaluate("h = { a: 0 }\nh, h[:a] = h, 1")
      expect(post.local(:h)).to be_a(Rigor::Type::Nominal)
    end

    it "forgets the indexed narrowing its store overwrites, as a plain `[]=` store does" do
      multi, = evaluate("m = {}\nm[:a] ||= \"d\"\nm[:a], y = 1, 2\nm[:a]")
      plain, = evaluate("m = {}\nm[:a] ||= \"d\"\nm[:a] = 1\nm[:a]")
      expect(multi).not_to eq(Rigor::Type::Combinator.constant_of("d"))
      expect(multi).to eq(plain)
    end

    it "keeps a narrowing on a slot the store does not name" do
      type, = evaluate("m = {}\nm[:a] ||= \"d\"\nm[:b], y = 1, 2\nm[:a]")
      expect(type).to eq(Rigor::Type::Combinator.constant_of("d"))
    end

    it "keeps the narrowings a variable key leaves, as a plain `[]=` store does" do
      multi, = evaluate("m = {}\nm[:a] ||= \"d\"\nk = [:a, :b].sample\nm[k], y = 1, 2\nm[:a]")
      plain, = evaluate("m = {}\nm[:a] ||= \"d\"\nk = [:a, :b].sample\nm[k] = 1\nm[:a]")
      expect(multi).to eq(plain)
    end

    it "softens a nil-bearing slot as a local in the same position is softened" do
      # The stored value carries no optimistic mark, but the join's `Dynamic[top]` floor keeps any fold off the
      # dropped `nil`; joining it would fire `possible-nil-receiver` on the correlated guard the fixture pins.
      _, multi = evaluate("t = {}\nopt = [true, false].sample ? \"s\" : nil\nt[:a], d = [opt, 1]")
      _, plain = evaluate("t = {}\nt[:a] = \"s\"")
      expect(multi.local(:t)).to eq(plain.local(:t))
    end

    it "leaves a collection the index target does not name at its literal shape" do
      _, post = evaluate("h = { a: 0 }\ng = {}\ng[:a], z = 1, 2")
      expect(post.local(:h)).to be_a(Rigor::Type::HashShape)
      expect(post.local(:g)).to be_a(Rigor::Type::Nominal)
    end

    it "drops the stored slot's `||=` narrowing as the plain `[]=` store does, and keeps another slot's" do
      seed = "h = { e: nil }\nh[:e] ||= 0\n"
      _, multi = evaluate("#{seed}h[:e], z = 1, 2\nv = h[:e]")
      _, plain = evaluate("#{seed}h[:e] = 1\nv = h[:e]")
      _, other = evaluate("#{seed}h[:f], z = 1, 2\nv = h[:e]")
      expect(multi.local(:v)).to eq(plain.local(:v))
      expect(multi.local(:v)).not_to eq(Rigor::Type::Combinator.constant_of(0))
      expect(other.local(:v)).to eq(Rigor::Type::Combinator.constant_of(0))
    end
  end

  describe "block return type uplift (Slice 6 phase C sub-phase 2)" do
    it "infers a per-position Tuple from `[1, 2, 3].map { |n| n.to_s }`" do
      # v0.0.6 phase 2 — per-element block re-evaluation over a Tuple-shaped receiver. Each position binds its own
      # constant to the block parameter, the body folds to the corresponding `Constant[String]`, and the assembled
      # answer is `Tuple[Constant["1"], Constant["2"], Constant["3"]]` — strictly tighter than the previous
      # `Array[union]` projection.
      type, _post = evaluate("[1, 2, 3].map { |n| n.to_s }")
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements.map(&:value)).to eq(%w[1 2 3])
    end

    it "binds numbered-parameter receivers and threads the block return type" do
      # `_1 + 1` folds element-wise to
      # `Tuple[Constant[2], Constant[3], Constant[4]]` via the
      # Phase 2 per-element uplift. Strictly tighter than the
      # earlier `Array[Constant[2] | Constant[3] | Constant[4]]`.
      type, _post = evaluate("[1, 2, 3].map { _1 + 1 }")
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements.map(&:value)).to eq([2, 3, 4])
    end

    it "does not raise when the receiver is unknown and the block has named parameters" do
      type, _post = evaluate("foo.map { |n| n.to_s }")
      expect(type).to eq(Rigor::Type::Combinator.untyped)
    end
  end

  describe "downstream inference benefits" do
    it "lets methods on bound locals resolve through RBS" do
      # Constant folding (v0.0.3 C) folds `1.succ` to `Constant[2]`, which is strictly more precise than the RBS-widened
      # `Nominal[Integer]`. The RBS dispatch tier is still exercised — the same call on a non-constant receiver returns
      # Nominal — see the wider-union tests in expression_typer_spec.rb.
      type, _post = evaluate(<<~RUBY)
        x = 1
        x.succ
      RUBY
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(2)
    end

    it "lets shape-typed locals resolve through dispatch" do
      # Slice 5 phase 2 picks the first element directly rather than the projected union; the test asserts the precise
      # answer.
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
      # The shape tier defers; RbsDispatch returns Array#[]'s projected type, which is Elem | nil under the
      # value-lattice.
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
      # The receiver is a HashShape{a: 1, b: 2}; Hash#each yields `[K, V]` tuples and the binder receives the tuple slot
      # type for each positional. We assert that the bindings are present rather than the exact tuple shape (which can
      # vary across RBS revisions).
      expect(events_k.first).not_to be_nil
      expect(events_v.first).not_to be_nil
    end

    it "defaults block parameters to Dynamic[Top] when the receiver has no RBS signature" do
      events, on_enter = watch_local_reads(:x)
      # `foo` resolves to an implicit-self call without a known signature. The block param falls back to Dynamic[Top].
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
      # `n + 1` is itself a CallNode, so the inner `n` read does not fire `on_enter`; we probe the entry scope at the
      # CallNode level instead, which sees the bound `n` via `type_of`.
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

    # `do |i; x|` — Ruby's explicit block-local declaration. The
    # `x` after the `;` introduces a fresh local that shadows
    # any outer `x`; writes to it inside the block MUST NOT
    # touch the outer binding. Rigor's `BlockParameterBinder`
    # documents that it skips these names; these specs lock the
    # observable behaviour the comment describes.
    describe "explicit block-local declarations (`do |i; x|`)" do
      it "preserves the outer local's narrowed type after the block returns" do
        _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
          x = 100
          [1, 2, 3].each do |i; x|
            x = i * 2
          end
        RUBY
        expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(100))
      end

      it "leaves the outer scope untouched even when only the block-local is written" do
        _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
          x = "outer"
          [1, 2, 3].each do |i; x|
            x = "inner-\#{i}"
          end
        RUBY
        expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of("outer"))
      end

      it "does not bind the block-local name in the post-call scope" do
        _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
          [1, 2, 3].each do |i; y|
            y = i * 2
          end
        RUBY
        expect(post.local(:y)).to be_nil
      end

      it "binds multiple `;`-prefixed locals all as block-scoped" do
        _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
          a = 1
          b = "two"
          [1].each do |_i; a, b|
            a = 999
            b = "rebound"
          end
        RUBY
        expect(post.local(:a)).to eq(Rigor::Type::Combinator.constant_of(1))
        expect(post.local(:b)).to eq(Rigor::Type::Combinator.constant_of("two"))
      end

      it "still treats normal block parameters before the `;` as parameters" do
        events, on_enter = watch_local_reads(:i)
        run_eval(default_env_scope, on_enter, "[1, 2, 3].each do |i; x| x = i; i end")
        expect(events.last.members).to contain_exactly(
          Rigor::Type::Combinator.constant_of(1),
          Rigor::Type::Combinator.constant_of(2),
          Rigor::Type::Combinator.constant_of(3)
        )
      end

      # Per Ruby's semantics, `;`-prefixed block-locals are freshly bound to `nil` at the start of each block
      # invocation. Reading the name before writing it must therefore yield `Constant[nil]` — NOT the outer binding's
      # value, which would be unsound (a runtime `nil.even?` would NoMethodError but the analyzer would claim the
      # receiver is the outer Integer).
      it "binds block-locals to Constant[nil] at block entry, shadowing the outer value" do
        events, on_enter = watch_local_reads(:x)
        run_eval(
          default_env_scope, on_enter, <<~RUBY
            x = 100
            [1].each do |_i; x|
              x
            end
          RUBY
        )
        expect(events).not_to be_empty
        expect(events.last).to eq(Rigor::Type::Combinator.constant_of(nil))
      end

      # The terminal `x` read is the block body's last expression: by then the block-local has been written from `x =
      # i`, so the read should see the Tuple-element union, not the outer `Constant[100]` shadow that `nil`-init
      # introduced.
      it "exposes the written type after the block-local is written" do
        events, on_enter = watch_local_reads(:x)
        run_eval(default_env_scope, on_enter, "x = 100; [1, 2, 3].each do |i; x| x = i; x end")
        expect(events.last).to be_a(Rigor::Type::Union)
        expect(events.last.members).to contain_exactly(
          Rigor::Type::Combinator.constant_of(1),
          Rigor::Type::Combinator.constant_of(2),
          Rigor::Type::Combinator.constant_of(3)
        )
      end
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

  describe "ivar/cvar/global writes thread through scope (Slice 7 phase 1)" do
    it "binds an InstanceVariableWriteNode into the post-scope ivars map" do
      type, post = evaluate("@x = 7")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(7))
      expect(post.ivar(:@x)).to eq(Rigor::Type::Combinator.constant_of(7))
    end

    it "threads ivar bindings across statements" do
      type, post = evaluate(<<~RUBY)
        @x = 1
        @y = @x + 2
        @y
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(3))
      expect(post.ivar(:@x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.ivar(:@y)).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "binds ClassVariableWriteNode and GlobalVariableWriteNode the same way" do
      _, post_c = evaluate("@@count = 5")
      _, post_g = evaluate("$verbose = true")
      expect(post_c.cvar(:@@count)).to eq(Rigor::Type::Combinator.constant_of(5))
      expect(post_g.global(:$verbose)).to eq(Rigor::Type::Combinator.constant_of(true))
    end

    it "joins ivar bindings across if-branches like locals" do
      _, post = evaluate(<<~RUBY)
        if cond
          @x = 1
        else
          @x = "two"
        end
      RUBY
      members = post.ivar(:@x).members.map(&:value)
      expect(members).to contain_exactly(1, "two")
    end

    it "starts ivars fresh inside a method body (no cross-method leak)" do
      observed = []
      on_enter = lambda do |node, s|
        next unless node.is_a?(Prism::InstanceVariableReadNode) && node.name == :@x

        observed << s.ivar(:@x)
      end
      bound = scope.with_ivar(:@x, Rigor::Type::Combinator.constant_of(99))
      described_class.new(scope: bound, on_enter: on_enter).evaluate(parse_program(<<~RUBY))
        def foo
          @x
        end
      RUBY
      # Inside the method body the outer @x = 99 binding MUST NOT be visible — `def` enters with a fresh scope.
      expect(observed.first).to be_nil
    end
  end

  # Issue #544 — the recording gate: a receiver with an untracked (Dynamic) constituent can hold a
  # caller-supplied slot value the `||=` keeps, so recording the default alone invents a fact (mail's
  # `options[:count] ||= :all` folded a reachable `count: 1` path away once #537 stopped hiding the
  # Dynamic arm behind a wrong overload pin).
  describe "indexed `||=` narrowing recording gate" do
    def indexed_key(name, key)
      Rigor::Scope::IndexedKey.new(receiver_kind: :local, receiver_name: name, key: key)
    end

    it "declines the record when the receiver carries an untracked Dynamic arm" do
      _, shaped = evaluate("h = {}")
      dynamic_hash = Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of("Hash"))
      seeded = scope.with_local(:options, Rigor::Type::Combinator.union(dynamic_hash, shaped.local(:h)))

      _, post = evaluate("options[:count] ||= :all", base_scope: seeded)

      expect(post.indexed_narrowings).not_to have_key(indexed_key(:options, :count))
    end

    it "still records for a fully tracked receiver (control)" do
      _, post = evaluate("params = {}\nparams[:f] ||= []")

      expect(post.indexed_narrowings).to have_key(indexed_key(:params, :f))
    end
  end

  # A compound index write reads `c[k]` before it stores. That read dispatches with the write node and
  # the scope as its call context, so a project `[]` with no signature answers from its body — the
  # value a plain `c[k]` read gets — rather than `Dynamic[top]`.
  describe "compound index write's implicit `[]` read" do
    def statement_result(source)
      ast = parse_program(source)
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      node = ast.statements.body.last
      index[node].evaluate(node).first
    end

    let(:klass) { "class C\n  def [](k) = 0\n  def []=(k, v); end\nend\nc = C.new\n" }

    it "stores the operator dispatched on the inferred read for `c[k] += v`" do
      expect(statement_result("#{klass}c[:a] += 1").describe).to eq("1")
    end

    it "stores `truthy(read) | v` for `c[k] ||= v` and `falsey(read) | v` for `c[k] &&= v`" do
      expect(statement_result("#{klass}c[:a] ||= \"s\"").describe).to eq('"s" | 0')
      expect(statement_result("#{klass}c[:a] &&= \"s\"").describe).to eq('"s"')
    end

    it "reads a project singleton `[]` the same way" do
      source = "class K\n  def self.[](k) = 0\n  def self.[]=(k, v); end\nend\nK[:a] += 1"
      expect(statement_result(source).describe).to eq("1")
    end
  end

  describe "compound writes rebind into post-scope (Slice 7 phase 3)" do
    def constant(value) = Rigor::Type::Combinator.constant_of(value)

    it "||= rebinds the local with union(narrow_truthy(current), rhs)" do
      _, post = evaluate(<<~RUBY)
        x = nil
        x ||= 1
      RUBY
      expect(post.local(:x)).to eq(constant(1))
    end

    it "&&= rebinds the local with union(narrow_falsey(current), rhs)" do
      _, post = evaluate(<<~RUBY)
        x = 1
        x &&= "two"
      RUBY
      expect(post.local(:x)).to eq(constant("two"))
    end

    it "+= rebinds via operator dispatch (constant folding when both sides are constants)" do
      _, post = evaluate(<<~RUBY)
        y = 0
        y += 5
      RUBY
      expect(post.local(:y)).to eq(constant(5))
    end

    it "ivar ||= rebinds the post-scope ivar map" do
      _, post = evaluate(<<~RUBY)
        @x = nil
        @x ||= "set"
      RUBY
      expect(post.ivar(:@x)).to eq(constant("set"))
    end

    it "ivar += dispatches the operator and rebinds" do
      _, post = evaluate(<<~RUBY)
        @count = 1
        @count += 2
      RUBY
      expect(post.ivar(:@count)).to eq(constant(3))
    end

    it "global ||= and cvar &&= rebind their respective maps" do
      _, post_g = evaluate("$g = nil; $g ||= 7")
      _, post_c = evaluate("@@k = 1; @@k &&= 9")
      expect(post_g.global(:$g)).to eq(constant(7))
      expect(post_c.cvar(:@@k)).to eq(constant(9))
    end
  end

  describe "cross-method ivar tracking via class accumulator (Slice 7 phase 2)" do
    it "seeds an instance method body's ivars from sibling-method writes when routed through ScopeIndexer" do
      # `def initialize` (not `def init`) is the soundness gate for the B2.3 read-before-write nil contribution: a write
      # in `initialize` runs before any other method body, so the analyzer does NOT widen `@cache` with nil here.
      ast = parse_program(<<~RUBY)
        class Foo
          def initialize; @cache = "hello"; end
          def get; @cache; end
        end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      # Find the @cache read node in the get body.
      read_node = nil
      Rigor::Source::NodeWalker.each(ast) do |n|
        read_node = n if n.is_a?(Prism::InstanceVariableReadNode) && n.name == :@cache
      end
      expect(index[read_node].ivar(:@cache)).to eq(Rigor::Type::Combinator.constant_of("hello"))
    end

    it "unions ivar types written in different sibling methods" do
      ast = parse_program(<<~RUBY)
        class Foo
          def init; @x = 1; end
          def reset; @x = nil; end
          def get; @x; end
        end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      get_def = nil
      Rigor::Source::NodeWalker.each(ast) do |n|
        get_def = n if n.is_a?(Prism::DefNode) && n.name == :get
      end
      union = index[get_def.body].ivar(:@x)
      expect(union).to be_a(Rigor::Type::Union)
      expect(union.members.map(&:value)).to contain_exactly(1, nil)
    end

    it "seeds cvars from sibling-method writes, including singleton-method bodies (Slice 7 phase 6)" do
      ast = parse_program(<<~RUBY)
        class Foo
          def init; @@count = 1; end
          def self.get; @@count; end
        end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      read_node = nil
      Rigor::Source::NodeWalker.each(ast) do |n|
        read_node = n if n.is_a?(Prism::ClassVariableReadNode) && n.name == :@@count
      end
      expect(index[read_node].cvar(:@@count)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "seeds globals from any program-level write into every method body (Slice 7 phase 6)" do
      ast = parse_program(<<~RUBY)
        $verbose = true
        def banner; $verbose; end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      read_node = nil
      Rigor::Source::NodeWalker.each(ast) do |n|
        read_node = n if n.is_a?(Prism::GlobalVariableReadNode) && n.name == :$verbose
      end
      expect(index[read_node].global(:$verbose)).to eq(Rigor::Type::Combinator.constant_of(true))
    end

    it "does NOT seed class-method (singleton) bodies — they have their own self" do
      ast = parse_program(<<~RUBY)
        class Foo
          def init; @cache = "hello"; end
          def self.get; @cache; end
        end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      read_node = nil
      Rigor::Source::NodeWalker.each(ast) do |n|
        read_node = n if n.is_a?(Prism::InstanceVariableReadNode)
      end
      # `def self.get`'s `@cache` is a class-level ivar of `Foo` the class object, NOT an instance ivar of a Foo
      # instance. The accumulator tracks only instance defs, so this read stays unbound.
      expect(index[read_node].ivar(:@cache)).to be_nil
    end
  end

  describe "transitive callee-escape content floor (ADR-57 slice 2 self-call channel)" do
    # An escaping block may content-mutate a captured local INDIRECTLY, by passing it as an argument to a
    # self-dispatched helper that mutates its own parameter — `collect_content_mutations` only sees a direct
    # `local[k] = v` / `local << x` write in the block body, so this channel is a separate resolve-the-callee path
    # (`floor_callee_escaped_args_for_call` / `callee_content_mutated_parameters`). It needs `top_level_def_for` to
    # resolve `helper`'s def, which requires a discovery-seeded scope — a bare `Scope.empty` never runs ScopeIndexer,
    # so (like the cross-method ivar tests above) this goes through `ScopeIndexer.index` directly.
    it "floors a captured local an escaping block passes to a self-call that mutates it directly" do
      ast = parse_program(<<~RUBY)
        def helper(arr)
          arr << 1
        end

        data = []
        Thread.new { helper(data) }
        data
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      _type, post = index[ast.statements].evaluate(ast.statements)
      expect(post.local(:data)).to eq(
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.untyped])
      )
    end

    it "floors a captured local a self-call mutates through ITS OWN nested block (the escaped, not direct, channel)" do
      ast = parse_program(<<~RUBY)
        def helper(h)
          foo.bar { h[:k] = 1 }
        end

        data = {}
        Thread.new { helper(data) }
        data
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope)
      _type, post = index[ast.statements].evaluate(ast.statements)
      expect(post.local(:data)).to eq(
        Rigor::Type::Combinator.nominal_of(
          "Hash", type_args: [Rigor::Type::Combinator.untyped, Rigor::Type::Combinator.untyped]
        )
      )
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
      # Pre-bind x with a fact, then escape; the with_local call inside the drop must invalidate the local_binding
      # bucket entry.
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

  describe "escaping-block collection content floor (ADR-57 slice 2)" do
    # A content-mutating (not rebinding) escaping/unknown block cannot be joined over a bounded evidence set (it may
    # run later, any number of times), so the sound continuation is the bare-collection floor: Array ->
    # `Array[Dynamic[top]]`, Hash -> `Hash[untyped, untyped]`, String -> `String` unchanged. These cases exercise
    # `content_floor_for` / `arrayish?` / `hashish?` / `stringish?` across both the direct-carrier and the
    # nilable-union pre-state shapes.
    it "floors a Nominal[Array] captured local to Array[Dynamic[top]]" do
      _, post = evaluate(<<~RUBY)
        arr = Array.new
        Thread.new { arr << 1 }
        arr
      RUBY
      expect(post.local(:arr)).to eq(
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.untyped])
      )
    end

    it "floors a Nominal[Hash] captured local to Hash[untyped, untyped]" do
      _, post = evaluate(<<~RUBY)
        h = Hash.new
        Thread.new { h[:k] = 1 }
        h
      RUBY
      expect(post.local(:h)).to eq(
        Rigor::Type::Combinator.nominal_of(
          "Hash", type_args: [Rigor::Type::Combinator.untyped, Rigor::Type::Combinator.untyped]
        )
      )
    end

    it "leaves a String captured local's carrier unchanged (no element parameter)" do
      _, post = evaluate(<<~RUBY)
        s = ""
        Thread.new { s << "x" }
        s
      RUBY
      expect(post.local(:s)).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "floors a nilable (Array | nil) captured local through the union arrayish? branch" do
      _, post = evaluate(<<~RUBY)
        arr = rand < 0.5 ? [] : nil
        Thread.new { arr << 1 }
        arr
      RUBY
      expect(post.local(:arr)).to eq(
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.untyped])
      )
    end

    it "floors a nilable (Hash | nil) captured local through the union hashish? branch" do
      _, post = evaluate(<<~RUBY)
        h = rand < 0.5 ? {} : nil
        Thread.new { h[:k] = 1 }
        h
      RUBY
      expect(post.local(:h)).to eq(
        Rigor::Type::Combinator.nominal_of(
          "Hash", type_args: [Rigor::Type::Combinator.untyped, Rigor::Type::Combinator.untyped]
        )
      )
    end

    it "widens a String captured local to its nominal base via the non-escaping join path" do
      # `join_content_for_param` (the slice-C non-escaping write-back join, not the escaping floor above) hits the
      # same stringish? contract from its own call site.
      _, post = evaluate(<<~RUBY)
        s = ""
        [1, 2].each { |n| s << n.to_s }
        s
      RUBY
      expect(post.local(:s)).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    # Issue #553 — the join arm is chosen by the pre-state's OWN evidence, never by the mutator set: `[]=` is legal
    # on Array, Hash, and countless index-writable classes, so an index-write on a shapeless binding must not
    # synthesize a hash carrier (mail's `compose_codepoints` mutated its untyped Array param through integer/range
    # index writes and handed `Hash[Integer | Range, …]` to its caller's `.pack`).
    it "does not synthesize a Hash from index writes on a shapeless captured binding" do
      _, post = evaluate(<<~RUBY)
        x = unknown_value
        [1].each { x[0..2] = 9 }
        x
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.untyped)
    end

    it "still joins index-write evidence when the pre-state carries hash shape" do
      _, post = evaluate(<<~RUBY)
        h = {}
        [1].each { h[:k] = 1 }
        h
      RUBY
      joined = post.local(:h)
      expect(joined).to be_a(Rigor::Type::Nominal)
      expect(joined.class_name).to eq("Hash")
      expect(joined.type_args.first).to eq(Rigor::Type::Combinator.constant_of(:k))
    end
  end

  describe "rescue variable binding" do
    # The rescue variable is only bound inside the rescue branch; the primary body's scope does not include it. After
    # the begin/rescue join the post-scope nil-injects the variable, so the observable type is `ExcType | nil`. These
    # tests verify the exception-type component.
    it "binds the rescue reference to StandardError when no classes named" do
      _, post = evaluate(<<~RUBY)
        begin
          risky
        rescue => e
          e
        end
      RUBY
      expect(post.local(:e).members).to include(Rigor::Type::Combinator.nominal_of("StandardError"))
    end

    it "binds the rescue reference to the named exception class" do
      _, post = evaluate(<<~RUBY)
        begin
          risky
        rescue TypeError => e
          e
        end
      RUBY
      nominal_members = post.local(:e).members.grep(Rigor::Type::Nominal)
      expect(nominal_members.map(&:class_name)).to contain_exactly("TypeError")
    end

    it "binds to the union of multiple exception classes" do
      _, post = evaluate(<<~RUBY)
        begin
          risky
        rescue TypeError, ArgumentError => e
          e
        end
      RUBY
      nominal_members = post.local(:e).members.grep(Rigor::Type::Nominal)
      expect(nominal_members.map(&:class_name)).to contain_exactly("TypeError", "ArgumentError")
    end

    it "leaves scope unchanged when no reference is given" do
      _, post = evaluate(<<~RUBY)
        begin
          risky
        rescue TypeError
          1
        end
      RUBY
      expect(post.local(:e)).to be_nil
    end

    it "each clause in a rescue chain gets its own exception type" do
      _, post = evaluate(<<~RUBY)
        begin
          risky
        rescue TypeError => e
          e
        rescue ArgumentError => e
          e
        end
      RUBY
      nominal_members = post.local(:e).members.grep(Rigor::Type::Nominal)
      expect(nominal_members.map(&:class_name)).to contain_exactly("TypeError", "ArgumentError")
    end

    # A rescue reference that is an index target (`rescue => h[:e]`) stores the exception through `[]=` on its
    # receiver, so it widens the receiver exactly as `rescue => e; h[:e] = e` does — otherwise the literal survives
    # and a later `h[:e] == 0` folds on its stale `0`.
    it "widens an index-target reference's receiver the way a `[]=` store of the exception does" do
      _, index = evaluate("h = { e: 0 }\nbegin\n  risky\nrescue => h[:e]\nend")
      _, plain = evaluate("h = { e: 0 }\nbegin\n  risky\nrescue => e\n  h[:e] = e\nend")
      expect(index.local(:h)).to eq(plain.local(:h))
      expect(index.local(:h).members).to include(a_kind_of(Rigor::Type::Nominal))
    end

    it "joins the rescued exception class into a seed that admits it" do
      _, index = evaluate("h = {}\nbegin\n  risky\nrescue TypeError => h[:e]\nend")
      _, plain = evaluate("h = {}\nbegin\n  risky\nrescue TypeError => e\n  h[:e] = e\nend")
      expect(index.local(:h)).to eq(plain.local(:h))
    end

    it "leaves a collection an index-target reference does not name at its literal shape" do
      _, post = evaluate("h = { e: 0 }\ng = {}\nbegin\n  risky\nrescue => g[:e]\nend")
      expect(post.local(:h)).to be_a(Rigor::Type::HashShape)
      expect(post.local(:g)).not_to be_a(Rigor::Type::HashShape)
    end

    it "drops the stored slot's `||=` narrowing as the arm's `[]=` store does, and keeps another slot's" do
      seed = "h = { e: nil }\nh[:e] ||= 0\n"
      _, index = evaluate("#{seed}begin\n  risky\nrescue => h[:e]\nend\nv = h[:e]")
      _, plain = evaluate("#{seed}begin\n  risky\nrescue => e\n  h[:e] = e\nend\nv = h[:e]")
      _, other = evaluate("#{seed}begin\n  risky\nrescue => h[:f]\nend\nv = h[:e]")
      expect(index.local(:v)).to eq(plain.local(:v))
      expect(index.local(:v)).not_to eq(Rigor::Type::Combinator.constant_of(0))
      expect(other.local(:v)).to eq(Rigor::Type::Combinator.constant_of(0))
    end
  end

  describe "case/in pattern variable binding" do
    # Issue #1122 — a pattern binds its names against the SUBJECT's type. A `case/in` with no `else` cannot fall
    # through (an unmatched subject raises `NoMatchingPatternError`), so the post-scope carries the matched type
    # itself rather than the `MatchType | nil` the shared `else` arm would inject.
    def pattern_types(type)
      type.is_a?(Rigor::Type::Union) ? type.members : [type]
    end

    it "binds a capture variable to the matched class type" do
      _, post = evaluate(<<~RUBY)
        case value
        in Integer => n
          n
        end
      RUBY
      expect(post.local(:n)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "handles a bare local variable target (captures subject type)" do
      _, post = evaluate(<<~RUBY)
        x = 1
        case x
        in n
          n
        end
      RUBY
      expect(post.local(:n)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "reads a tuple subject element-wise" do
      _, post = evaluate(<<~RUBY)
        case [1, "a"]
        in [i, s]
          [i, s]
        end
      RUBY
      expect(post.local(:i)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:s)).to eq(Rigor::Type::Combinator.constant_of("a"))
    end

    it "binds `T` per slot for an `Array[T]` subject" do
      _, post = evaluate(<<~RUBY)
        case ARGV
        in [first, second]
          [first, second]
        end
      RUBY
      expect(post.local(:first)).to eq(Rigor::Type::Combinator.nominal_of("String"))
      expect(post.local(:second)).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "distributes a union subject over the pattern, dropping a member that cannot match" do
      _, post = evaluate(<<~RUBY)
        maybe = flag ? [1, "a"] : nil
        case maybe
        in [i, s]
          [i, s]
        end
      RUBY
      expect(post.local(:i)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:s)).to eq(Rigor::Type::Combinator.constant_of("a"))
    end

    it "binds a capture over a pattern to the whole subject as well as the pattern's own names" do
      _, post = evaluate(<<~RUBY)
        case [1, "a"]
        in [x, y] => whole
          [whole]
        end
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:whole)).to eq(Rigor::Type::Combinator.tuple_of(
                                         Rigor::Type::Combinator.constant_of(1),
                                         Rigor::Type::Combinator.constant_of("a")
                                       ))
    end

    it "extracts bindings from an array pattern" do
      _, post = evaluate(<<~RUBY)
        case value
        in [Integer => a, String => b]
          [a, b]
        end
      RUBY
      nominal_a = pattern_types(post.local(:a)).grep(Rigor::Type::Nominal)
      nominal_b = pattern_types(post.local(:b)).grep(Rigor::Type::Nominal)
      expect(nominal_a.map(&:class_name)).to contain_exactly("Integer")
      expect(nominal_b.map(&:class_name)).to contain_exactly("String")
    end

    it "binds the splat variable in an array pattern to the tuple's middle elements" do
      _, post = evaluate(<<~RUBY)
        case [1, "a", 3]
        in [Integer => first, *rest]
          rest
        end
      RUBY
      nominal_first = pattern_types(post.local(:first)).grep(Rigor::Type::Nominal)
      expect(nominal_first.map(&:class_name)).to contain_exactly("Integer")
      expect(post.local(:rest)).to eq(Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of("a"),
                                                                       Rigor::Type::Combinator.constant_of(3)))
    end

    it "binds a find pattern's requireds to the union of their candidate positions" do
      _, post = evaluate(<<~RUBY)
        case [1, "a", 3]
        in [*, middle, *]
          middle
        end
      RUBY
      expect(pattern_types(post.local(:middle))).to contain_exactly(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of("a"),
        Rigor::Type::Combinator.constant_of(3)
      )
    end

    it "binds find-pattern *pre / *post splats to Array of the element union" do
      _, post = evaluate(<<~RUBY)
        case [1, "a", 3]
        in [*pre, Integer, *post]
          [pre, post]
        end
      RUBY
      %i[pre post].each do |name|
        expect(post.local(name)).to eq(
          Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.constant_of(1),
            Rigor::Type::Combinator.constant_of("a"),
            Rigor::Type::Combinator.constant_of(3)
          )])
        )
      end
    end

    it "binds the **rest splat in a hash pattern to Hash[Symbol, value]" do
      _, post = evaluate(<<~RUBY)
        case { name: "x", age: 1 }
        in { name:, **rest }
          rest
        end
      RUBY
      expect(post.local(:rest)).to eq(
        Rigor::Type::Combinator.nominal_of("Hash", type_args: [
                                             Rigor::Type::Combinator.nominal_of("Symbol"),
                                             Rigor::Type::Combinator.union(Rigor::Type::Combinator.constant_of("x"), Rigor::Type::Combinator.constant_of(1))
                                           ])
      )
    end

    it "extracts bindings from a hash pattern" do
      _, post = evaluate(<<~RUBY)
        case { name: "x", age: 1 }
        in { name: String => n, age: Integer => a }
          [n, a]
        end
      RUBY
      nominal_n = pattern_types(post.local(:n)).grep(Rigor::Type::Nominal)
      nominal_a = pattern_types(post.local(:a)).grep(Rigor::Type::Nominal)
      expect(nominal_n.map(&:class_name)).to contain_exactly("String")
      expect(nominal_a.map(&:class_name)).to contain_exactly("Integer")
    end

    it "reads a hash pattern's values out of a hash shape subject" do
      _, post = evaluate(<<~RUBY)
        case { name: "x" }
        in { name: }
          name
        end
      RUBY
      expect(post.local(:name)).to eq(Rigor::Type::Combinator.constant_of("x"))
    end

    it "keeps the Dynamic[top] floor for a subject nothing can decompose" do
      _, post = evaluate(<<~RUBY)
        case "not a pair"
        in [a, b]
          [a, b]
        end
      RUBY
      expect(post.local(:a)).to eq(Rigor::Type::Combinator.untyped)
      expect(post.local(:b)).to eq(Rigor::Type::Combinator.untyped)
    end

    it "binds the one-line `=>` and `in` forms" do
      _, post = evaluate(<<~RUBY)
        [1, "a"] => [required_x, required_y]
        if [1, "a"] in [predicate_x, predicate_y]
          nil
        end
      RUBY
      expect(post.local(:required_x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:required_y)).to eq(Rigor::Type::Combinator.constant_of("a"))
      expect(post.local(:predicate_x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:predicate_y)).to eq(Rigor::Type::Combinator.constant_of("a"))
    end

    it "binds an alternation+capture target to the union of the alternates" do
      _, post = evaluate(<<~RUBY)
        case value
        in Integer | String => x
          x
        end
      RUBY
      nominal_members = pattern_types(post.local(:x)).grep(Rigor::Type::Nominal)
      expect(nominal_members.map(&:class_name)).to contain_exactly("Integer", "String")
    end

    it "merges bindings across alternation branches by name" do
      _, post = evaluate(<<~RUBY)
        case value
        in [Integer => i] | [String => i]
          i
        end
      RUBY
      nominal_members = pattern_types(post.local(:i)).grep(Rigor::Type::Nominal)
      expect(nominal_members.map(&:class_name)).to contain_exactly("Integer", "String")
    end

    # Issue #1122 — an unmatched `case/in` with no `else` raises `NoMatchingPatternError`, so a name a clause
    # bound is bound on every path that reaches the continuation. A `case/when` really does fall through as
    # `nil`, and a `case/in` WITH an `else` can be reached without any pattern matching.
    it "keeps a `case/when` fall-through nil arm" do
      _, post = evaluate(<<~RUBY)
        case flag
        when 1
          x = 1
        end
      RUBY
      expect(pattern_types(post.local(:x))).to contain_exactly(
        Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of(nil)
      )
    end

    it "nil-injects a pattern binding across an `else` clause" do
      _, post = evaluate(<<~RUBY)
        case [1, "a"]
        in [i, s]
          [i, s]
        else
          nil
        end
      RUBY
      expect(pattern_types(post.local(:i))).to contain_exactly(
        Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of(nil)
      )
    end
  end

  describe "MatchWriteNode (named regex captures)" do
    it "binds each named capture to String | nil" do
      _, post = evaluate(<<~RUBY)
        /(?<year>\d+)-(?<month>\d+)/ =~ date_str
      RUBY
      string_or_nil = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("String"),
        Rigor::Type::Combinator.constant_of(nil)
      )
      expect(post.local(:year)).to eq(string_or_nil)
      expect(post.local(:month)).to eq(string_or_nil)
    end

    it "binds multiple captures independently" do
      _, post = evaluate(<<~RUBY)
        /(?<a>x)(?<b>y)/ =~ str
      RUBY
      expect(post.local(:a)).to be_a(Rigor::Type::Union)
      expect(post.local(:b)).to be_a(Rigor::Type::Union)
    end

    # `if /(?<x>...)/ =~ str` — Ruby guarantees the named capture is a `String` inside the truthy branch (the match
    # succeeded; the capture group must have participated for the match to be truthy with a non-optional group). The
    # else branch sees `nil`.
    describe "narrowing through `if regex =~ str`" do
      let(:string_t) { Rigor::Type::Combinator.nominal_of("String") }
      let(:nil_t) { Rigor::Type::Combinator.constant_of(nil) }
      let(:decimal_int_string_t) { Rigor::Type::Combinator.decimal_int_string }
      let(:default_env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

      def first_local_seen(name, source)
        events = []
        on_enter = lambda do |node, sc|
          next unless node.is_a?(Prism::LocalVariableReadNode) && node.name == name

          events << sc.local(name)
        end
        Rigor::Inference::StatementEvaluator.new(
          scope: default_env_scope, on_enter: on_enter
        ).evaluate(parse_program(source))
        events.first
      end

      # When the named-capture body is outside the v0.1.1 recogniser table (e.g. `.+`), the truthy branch still narrows
      # to plain `String` per the v0.1.0 baseline.
      it "narrows the capture to String inside the truthy branch (recogniser fallback)" do
        observed = first_local_seen(:rest, <<~RUBY)
          if /(?<rest>.+)/ =~ str
            rest
          end
        RUBY
        expect(observed).to eq(string_t)
      end

      it "narrows the capture to nil inside the falsey branch" do
        observed = first_local_seen(:year, <<~RUBY)
          if /(?<year>\\d+)/ =~ str
            nil
          else
            year
          end
        RUBY
        expect(observed).to eq(nil_t)
      end

      # `\d+` triggers the v0.1.1 recogniser, so the truthy edge carries `decimal-int-string`; rejoining with the falsey
      # `nil` edge widens back to a `decimal-int-string | nil` union (still tighter than the v0.1.0 `String | nil`).
      it "joins back to <refinement> | nil after the if" do
        _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
          if /(?<year>\\d+)/ =~ str
            "matched"
          end
          year
        RUBY
        expect(post.local(:year)).to eq(Rigor::Type::Combinator.union(decimal_int_string_t, nil_t))
      end

      it "narrows symmetrically through `unless` (falsey branch is the matched edge)" do
        observed = first_local_seen(:year, <<~RUBY)
          unless /(?<year>\\d+)/ =~ str
            "no match"
          else
            year
          end
        RUBY
        expect(observed).to eq(decimal_int_string_t)
      end

      # ---- v0.1.1 Track 1 slice 1: regex pattern -> refinement ----

      it "narrows `\\d+` named capture to decimal-int-string" do
        observed = first_local_seen(:year, <<~RUBY)
          if /(?<year>\\d+)/ =~ str
            year
          end
        RUBY
        expect(observed).to eq(decimal_int_string_t)
      end

      it "narrows `\\d{N}` and `\\d{N,M}` bounded forms to decimal-int-string" do
        source = <<~RUBY
          if /(?<year>\\d{4})-(?<month>\\d{1,2})/ =~ str
            year
            month
          end
        RUBY
        expect(first_local_seen(:year, source)).to eq(decimal_int_string_t)
        expect(first_local_seen(:month, source)).to eq(decimal_int_string_t)
      end

      # #1004 — `hex-int-string` / `octal-int-string` require the `0x` / `0o` prefix (`refined.rb`);
      # a bare `\h+` / `[0-9a-fA-F]+` / `[0-7]+` capture matches a prefix-free digit run ("ff", "17"),
      # so the sound narrowing is `non-empty-string`, never those refinements.
      it "narrows `\\h+` named capture to non-empty-string, NEVER hex-int-string" do
        observed = first_local_seen(:hash, <<~RUBY)
          if /(?<hash>\\h+)/ =~ str
            hash
          end
        RUBY
        expect(observed).to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "narrows `[0-9a-fA-F]+` named capture to non-empty-string, NEVER hex-int-string" do
        observed = first_local_seen(:hex, <<~RUBY)
          if /(?<hex>[0-9a-fA-F]+)/ =~ str
            hex
          end
        RUBY
        expect(observed).to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "narrows `[0-7]+` named capture to non-empty-string, NEVER octal-int-string" do
        observed = first_local_seen(:oct, <<~RUBY)
          if /(?<oct>[0-7]+)/ =~ str
            oct
          end
        RUBY
        expect(observed).to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "narrows `[a-z]+` named capture to lowercase-string" do
        observed = first_local_seen(:tag, <<~RUBY)
          if /(?<tag>[a-z]+)/ =~ str
            tag
          end
        RUBY
        expect(observed).to eq(Rigor::Type::Combinator.lowercase_string)
      end

      it "narrows `[A-Z]+` named capture to uppercase-string" do
        observed = first_local_seen(:tag, <<~RUBY)
          if /(?<tag>[A-Z]+)/ =~ str
            tag
          end
        RUBY
        expect(observed).to eq(Rigor::Type::Combinator.uppercase_string)
      end

      it "narrows `[[:digit:]]+` named capture to numeric-string" do
        observed = first_local_seen(:digits, <<~RUBY)
          if /(?<digits>[[:digit:]]+)/ =~ str
            digits
          end
        RUBY
        expect(observed).to eq(Rigor::Type::Combinator.numeric_string)
      end

      it "mixes recognised and unrecognised captures in a single regex" do
        source = <<~RUBY
          if /(?<year>\\d{4})-(?<rest>.+)/ =~ str
            year
            rest
          end
        RUBY
        expect(first_local_seen(:year, source)).to eq(decimal_int_string_t)
        expect(first_local_seen(:rest, source)).to eq(string_t)
      end

      # `\d*` admits the empty string, which is not a valid `decimal-int-string` (the carrier excludes `""`). The
      # recogniser rejects unbounded-zero quantifiers and the fallback to plain `String` keeps the carrier sound.
      it "falls back to String for `\\d*` and other zero-length-admitting forms" do
        observed = first_local_seen(:n, <<~RUBY)
          if /(?<n>\\d*)/ =~ str
            n
          end
        RUBY
        expect(observed).to eq(string_t)
      end
    end
  end

  # Survey item (b) — `=~` with a regex literal binds the match-data globals (`$~`, `$&`, `$\``, `$'`, `$+`, `$1..$N`)
  # on each predicate edge so subsequent reads inside an `unless ... raise` guard see the tightened type.
  describe "regex `=~` predicate narrowing (numbered globals)" do
    let(:string_t) { Rigor::Type::Combinator.nominal_of("String") }
    let(:nil_t) { Rigor::Type::Combinator.constant_of(nil) }
    let(:default_env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

    it "binds $1..$N to String on the truthy edge of `regex =~ str`" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        unless /(\\d+)-(\\w+)/ =~ value
          raise "bad"
        end
      RUBY
      # After `unless ... raise`, only the predicate-truthy edge survives — $1 and $2 are narrowed to String.
      expect(post.global(:$1)).to eq(string_t)
      expect(post.global(:$2)).to eq(string_t)
    end

    it "binds $~ to MatchData on the truthy edge" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        unless /(\\d+)/ =~ value
          raise
        end
      RUBY
      expect(post.global(:$~)).to be_a(Rigor::Type::Nominal)
      expect(post.global(:$~).class_name).to eq("MatchData")
    end

    it "binds back-reference globals ($&, $`, $', $+) to String on the truthy edge" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        unless /(\\d+)/ =~ value
          raise
        end
      RUBY
      %i[$& $` $' $+].each do |name|
        expect(post.global(name)).to eq(string_t), "#{name}: #{post.global(name).inspect}"
      end
    end

    it "binds $~ / $1 to nil on the falsey edge" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        if /(\\d+)/ =~ value
          raise "matched"
        end
      RUBY
      expect(post.global(:$~)).to eq(nil_t)
      expect(post.global(:$1)).to eq(nil_t)
    end

    it "recognises the reverse argument order (`str =~ regex`)" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        unless value =~ /(\\d+)/
          raise
        end
      RUBY
      expect(post.global(:$1)).to eq(string_t)
    end

    it "does not count non-capturing groups (`(?:...)`)" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        unless /(?:foo)(\\d+)/ =~ value
          raise
        end
      RUBY
      expect(post.global(:$1)).to eq(string_t)
      # No $2 — the (?:foo) is non-capturing.
      expect(post.global(:$2)).to be_nil
    end

    it "does not narrow when neither side is a regex literal" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        unless lhs =~ rhs
          raise
        end
      RUBY
      expect(post.global(:$1)).to be_nil
    end

    # Issue #1358 — a block runs in the enclosing frame, so a match in its body rebinds the frame's `$~`.
    it "forgets the narrowing after a call whose block may match" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        raise unless /(\\d+)/ =~ value
        items.each { |i| i =~ /(z)/ }
      RUBY
      expect(post.global(:$1)).to be_nil
      expect(post.global(:$~)).to be_nil
    end

    it "keeps the narrowing after a call whose block cannot match" do
      _, post = default_env_scope.evaluate(parse_program(<<~RUBY))
        raise unless /(\\d+)/ =~ value
        items.each { |i| i.upcase }
      RUBY
      expect(post.global(:$1)).to eq(string_t)
    end

    # Issue #1364 — a method defined in Ruby runs in a frame of its own, so a call into one leaves the caller's `$~`.
    # The rule reads the frame, which a method, class or file body stamps; without one an implicit-self call forgets
    # as it did before.
    def evaluate_framed(source)
      program = parse_program(source)
      default_env_scope.with_match_frame(program).evaluate(program)
    end

    it "keeps the narrowing after an implicit-self or `self.` call in a frame" do
      _, post = evaluate_framed(<<~RUBY)
        raise unless /(\\d+)/ =~ value
        log("parsed")
        self.log("x")
      RUBY
      expect(post.global(:$1)).to eq(string_t)

      _, unframed = default_env_scope.evaluate(parse_program(<<~RUBY))
        raise unless /(\\d+)/ =~ value
        log("parsed")
      RUBY
      expect(unframed.global(:$1)).to be_nil
    end

    it "forgets the narrowing after an implicit-self `eval`, or a call whose argument runs a match" do
      ["eval(src)", 'log(value.sub(/=/, ": "))'].each do |call|
        _, post = evaluate_framed(<<~RUBY)
          raise unless /(\\d+)/ =~ value
          #{call}
        RUBY
        expect(post.global(:$1)).to be_nil
      end
    end

    it "forgets at an implicit-self call, and only there, in a frame holding a block that may match" do
      _, post = evaluate_framed(<<~RUBY)
        on { |l| l =~ /(z)/ }
        raise unless /(\\d+)/ =~ value
        value.upcase
      RUBY
      expect(post.global(:$1)).to eq(string_t)

      _, post = evaluate_framed(<<~RUBY)
        on { |l| l =~ /(z)/ }
        raise unless /(\\d+)/ =~ value
        emit("q")
      RUBY
      expect(post.global(:$1)).to be_nil
    end

    # A `yield` rebinds this frame only when the caller passes a C-function proc; it keeps the narrowing, as before.
    it "keeps the narrowing after a `yield`" do
      _, post = evaluate_framed(<<~RUBY)
        raise unless /(\\d+)/ =~ value
        yield(value)
      RUBY
      expect(post.global(:$1)).to eq(string_t)
    end

    # Issue #1365 — a call rebinds the frame's `$~` by what it calls and its arguments' types, in any position.
    it "keeps the narrowing after a lookup whose argument is not a Regexp, and after `match?`" do
      ["val = row[:name]", 'csv.split(",")', "list.index(3)", "value.match?(/x/)", "String === value",
       '$stdout.puts(row[:name], [csv.split(",")])', "h[key] = 1", "x = [h[key], 1]", "h[key] += 1",
       "record.public_send(\"\#{attr}=\", value)", 'klass.class_eval("def foo; end")'].each do |call|
        _, post = evaluate_framed(<<~RUBY)
          raise unless /(\\d+)/ =~ value
          #{call}
        RUBY
        expect(post.global(:$1)).to eq(string_t), call
      end
    end

    it "forgets the narrowing after an explicit-receiver builtin, or an operand or literal call, that rebinds it" do
      ["value !~ /(z)/", "value.start_with?(/(z)/)", %q|Kernel.eval('"zz" =~ /(q)/')|, 'out.push(value.sub(/q/, ""))',
       "[value.index(/(q)/)]", "x = { a: items.find { |i| i =~ /(z)/ } }", "x = value[/(q)/] rescue nil",
       'super(value.sub(/q/, ""))', 'X = value.sub(/q/, "")', "obj.attr ||= value[/(q)/]",
       "value[/(q)/] ||= 'x'"].each do |call|
        _, post = evaluate_framed(<<~RUBY)
          raise unless /(\\d+)/ =~ value
          #{call}
        RUBY
        expect(post.global(:$1)).to be_nil, call
      end
    end

    # A name the table forgot on before keeps forgetting unless every argument is a non-Regexp literal: a flow type
    # can be stale (#1380), so a typed `String` argument does not prove the call cannot match.
    it "forgets the narrowing after a lookup the table named whose argument is not a literal" do
      ["row[key]", "val = value.index(str)", "value.split(\"\#{sep}\")"].each do |call|
        _, post = evaluate_framed(<<~RUBY)
          str = "x"
          raise unless /(\\d+)/ =~ value
          #{call}
        RUBY
        expect(post.global(:$1)).to be_nil, call
      end
    end

    # Ruby runs the receiver chain before the method, so the call's own block reads the rebound globals.
    it "forgets the narrowing before the call's own block when its receiver chain rebinds it" do
      program = parse_program(<<~RUBY)
        raise unless /(\\d+)/ =~ value
        value.sub(/q/, "").each_char { |c| c }
      RUBY
      entries = {}
      recorder = ->(node, scope) { entries[node] = scope if node.is_a?(Prism::BlockNode) }
      framed = default_env_scope.with_match_frame(program)
      described_class.new(scope: framed, on_enter: recorder).evaluate(program)
      expect(entries.values.map { |entry| entry.global(:$1) }).to all(be_nil)
      expect(entries).not_to be_empty
    end

    # Issue #1361 — a thread's, fiber's or ractor's root block runs with a slot of its own and enters unbound; a
    # `define_method` body reads the definer's slot whenever the method is called and enters untyped. A root block's
    # match leaves the creator's narrowing, as does an implicit-self call in a frame whose only matching block is one.
    it "enters a root block unbound and a `define_method` body untyped, and keeps the narrowing after a root block" do
      program = parse_program(<<~RUBY)
        worker = Thread.new { value =~ /(z)/ }
        raise unless /(\\d+)/ =~ value
        Thread.new { $1 }
        fiber = Fiber.new { $1 }
        define_method(:x) { $1 }
        items.each { $1 }
        log("started")
        worker.join
      RUBY
      entries = []
      recorder = ->(node, scope) { entries << scope.global(:$1) if node.is_a?(Prism::BlockNode) }
      framed = default_env_scope.with_match_frame(program)
      _, post = described_class.new(scope: framed, on_enter: recorder).evaluate(program)
      expect(entries.last(4)).to eq([nil, nil, Rigor::Type::Combinator.untyped, string_t])
      expect(post.global(:$1)).to eq(string_t)
    end
  end

  # Issue #1360 — `$!` / `$@` are bound in a rescue clause and restored once the `begin` exits however it exits; `$?`
  # is bound after a subprocess the statement certainly ran.
  describe "`$!` / `$@` / `$?`" do
    let(:env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }
    let(:error_t) { Rigor::Type::Combinator.nominal_of("StandardError") }
    let(:argument_t) { Rigor::Type::Combinator.nominal_of("ArgumentError") }
    let(:status_t) { Rigor::Type::Combinator.nominal_of("Process::Status") }

    # The binding of `name` each read of it records in the per-node scope index, in source order, and the scope after.
    def special_reads(source, name, base: env_scope)
      program = parse_program(source)
      reads = []
      recorder = lambda do |node, scope|
        reads << scope.global(name) if node.is_a?(Prism::GlobalVariableReadNode) && node.name == name
      end
      _, post = described_class.new(scope: base.with_match_frame(program), on_enter: recorder).evaluate(program)
      [reads, post]
    end

    it "binds `$!` and `$@` in a rescue clause, with or without a reference, and restores the entry past the `begin`" do
      reads, post = special_reads(<<~RUBY, :$!)
        begin
          Integer("x")
        rescue ArgumentError => e
          $!
        rescue
          $!
        end
        $!
      RUBY
      expect(reads).to eq([argument_t, error_t, nil])
      expect(post.global(:$!)).to be_nil
      expect(post.global(:$@)).to be_nil

      outer = env_scope.with_global(:$!, argument_t)
      reads, post = special_reads("begin\n  x\nrescue\n  $!\nend\n$!\n", :$!, base: outer)
      expect(reads).to eq([error_t, argument_t])
      expect(post.global(:$!)).to eq(argument_t)
    end

    it "restores the entry on a `break` or `next` that leaves a rescue clause or a rescue modifier" do
      outer = env_scope.with_global(:$!, argument_t)
      ["while ok\n  begin\n    x\n  rescue\n    break\n  end\nend",
       "while ok\n  begin\n    x\n  rescue\n    next\n  end\nend",
       "while ok\n  y = (x rescue break)\nend"].each do |loop_source|
        _, post = special_reads("#{loop_source}\n", :$!, base: outer)
        expect(post.global(:$!)).to eq(argument_t), loop_source
      end
    end

    it "reads `$!`, `$@` and `$?` unbound in an `ensure` clause, and keeps what it entered with past it" do
      bound = env_scope.with_global(:$!, argument_t).with_global(:$?, status_t)
      reads, post = special_reads("begin\n  x\nensure\n  $!\n  $?\nend\n", :$!, base: bound)
      expect(reads).to eq([nil])
      expect(post.global(:$!)).to eq(argument_t)
      expect(post.global(:$?)).to eq(status_t)

      reads, post = special_reads("begin\n  x\nensure\n  $?\n  system('y')\nend\n", :$?)
      expect(reads).to eq([nil])
      expect(post.global(:$?)).to eq(status_t)
    end

    it "binds a rescue modifier's fallback to a `StandardError` and restores the entry past it" do
      # The arm is threaded outside the per-node index, so its write shows what it read.
      _, post = special_reads("y = (x rescue (z = $!))\n", :$!)
      expect(post.local(:z)).to eq(Rigor::Type::Combinator.union(error_t, Rigor::Type::Combinator.constant_of(nil)))
      expect(post.global(:$!)).to be_nil
      _, post = special_reads("y = (x rescue (z = $!))\n", :$!, base: env_scope.with_global(:$!, argument_t))
      expect(post.global(:$!)).to eq(argument_t)
      # A fallback that guards `$!` by its class reads it unbound (#1429).
      _, post = special_reads("y = (x rescue (z = ($!.is_a?(KeyError) ? $! : nil)))\n", :$!)
      expect(post.local(:z).describe(:short)).to eq("Dynamic[top]?")
      type, = evaluate("(raise 'm') rescue $!", base_scope: env_scope)
      expect(type).to eq(error_t)
    end

    # A backtick, `%x` or `system` sets `$?` to nil before it runs the child, so a raise while it waits leaves it nil.
    it "unbinds `$?` in a rescue clause, past a modifier whose fallback may fall through, and in a retried body" do
      bound = env_scope.with_global(:$?, status_t)
      reads, post = special_reads("begin\n  `sleep 2`\nrescue\n  $?\nend\n$?\n", :$?, base: bound)
      expect(reads).to eq([nil, nil])
      expect(post.global(:$?)).to be_nil
      _, post = special_reads("x = (`sleep 2` rescue nil)\n", :$?, base: bound)
      expect(post.global(:$?)).to be_nil
      _, post = special_reads("def m\n  x = (y rescue return)\nend\nx = (y rescue return)\n", :$?, base: bound)
      expect(post.global(:$?)).to eq(status_t)
      reads, = special_reads("begin\n  $?\n  `sleep 2`\nrescue\n  retry\nend\n", :$?, base: bound)
      expect(reads).to all(be_nil)
      expect(reads).not_to be_empty
      reads, = special_reads("begin\n  $?\n  `sleep 2`\nrescue\n  1\nend\n", :$?, base: bound)
      expect(reads).to eq([status_t])
    end

    # A rescue in an operand or a block the statement passes never joins its scope back into the statement's.
    it "unbinds `$?` past a statement that may fall through a rescue in its own frame" do
      bound = env_scope.with_global(:$?, status_t)
      ["[1].each { x rescue nil }", "[1].each do\n  x\nrescue\n  nil\nend", "warn(begin; x; rescue; nil; end)",
       "warn((x rescue nil))", "a = [(x rescue nil)]", "t(5) do\n  begin\n    x\n  rescue\n    nil\n  end\nend"]
        .each do |statement|
          _, post = special_reads("#{statement}\n", :$?, base: bound)
          expect(post.global(:$?)).to be_nil, statement
        end
      ["f = proc { x rescue nil }", "register(-> { x rescue nil })", "private def m = (x rescue nil)",
       "warn((x rescue return))",
       "Thread.new { x rescue nil }", "[1].each { x }"].each do |statement|
        _, post = special_reads("#{statement}\n", :$?, base: bound)
        expect(post.global(:$?)).to eq(status_t), statement
      end
    end

    it "binds `$?` after a subprocess a statement certainly ran, and not in a file that may clear it" do
      ["`true`", "%x(true)", "system('true')", "out = `a`.strip", "puts(`a`)", "ok = Kernel.system('x')",
       "Process.wait(pid)", "if system('x') then 1 end"].each do |statement|
        _, post = special_reads("#{statement}\n", :$?)
        expect(post.global(:$?)).to eq(status_t), statement
      end
      ["[`a`]", "x&.y(`a`)", "system('x') if ok", "items.each { `a` }", "Process.wait(pid, 1)"].each do |statement|
        _, post = special_reads("#{statement}\n", :$?)
        expect(post.global(:$?)).to be_nil, statement
      end
      clearing = env_scope.with_discovery(env_scope.discovery.with(clears_last_status: true))
      _, post = special_reads("system('true')\n", :$?, base: clearing)
      expect(post.global(:$?)).to be_nil
    end
  end

  # Issue #1359 — `$_` shares the match globals' frame slot: a condition on a reader narrows it, and code that may
  # set it after the narrowing forgets it.
  describe "`$_` last-line narrowing" do
    let(:string_t) { Rigor::Type::Combinator.nominal_of("String") }
    let(:nil_t) { Rigor::Type::Combinator.constant_of(nil) }
    let(:default_env_scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

    # The `$_` a read of it records in the per-node scope index, in source order.
    def last_line_reads(source)
      program = parse_program(source)
      reads = []
      recorder = lambda do |node, scope|
        reads << scope.global(:$_) if node.is_a?(Prism::GlobalVariableReadNode) && node.name == :$_
      end
      framed = default_env_scope.with_match_frame(program)
      _, post = described_class.new(scope: framed, on_enter: recorder).evaluate(program)
      [reads, post]
    end

    it "narrows `$_` on a reader condition's edges and leaves it nil after a `while gets` loop" do
      reads, post = last_line_reads(<<~RUBY)
        if $stdin.gets then $_ else $_ end
        $stdin.gets or raise
        $_
        while $stdin.gets
          $_
        end
      RUBY
      expect(reads).to eq([string_t, nil_t, string_t, string_t])
      expect(post.global(:$_)).to eq(nil_t)
    end

    it "leaves `$_` unbound after a reader that is not a condition, and on an untyped receiver's condition" do
      reads, = last_line_reads(<<~RUBY)
        if $stdin.gets
          gets
          $_
        end
        $_ if io.gets
        $_ if gets
      RUBY
      expect(reads).to eq([nil, nil, nil])
    end

    it "forgets `$_` after an operand, literal or block that may set it, and keeps it across a Ruby method call" do
      ["x = gets.to_s", "log(gets)", "pair = [gets, 1]", "items.each { |i| i.gets }", "items.each(&:gets)",
       "io.send(:gets)", "Enumerator.new { gets }.to_a"].each do |call|
        reads, = last_line_reads("if $stdin.gets\n  #{call}\n  $_\nend\n")
        expect(reads).to eq([nil]), call
      end
      ["log('x')", "self.log('y')", "items.map { |i| i }", "Thread.new { gets }.join"].each do |call|
        reads, = last_line_reads("if $stdin.gets\n  #{call}\n  $_\nend\n")
        expect(reads).to eq([string_t]), call
      end
    end

    it "forgets `$_` where a body that may set it runs again, and where a rescue clause reads it" do
      ["while ok\n  $_\n  gets\nend", "for i in items\n  $_\n  gets\nend",
       "begin\n  $stdin.readline\nrescue EOFError\n  $_\nend",
       "begin\n  $_\n  gets\n  raise 'x'\nrescue RuntimeError\n  retry\nend"].each do |body|
        reads, = last_line_reads("if $stdin.gets\n#{body}\nend\n")
        expect(reads).to all(be_nil), body
        expect(reads).not_to be_empty
      end
      reads, = last_line_reads("if $stdin.gets\n  while ok\n    $_\n  end\nend\n")
      expect(reads).to eq([string_t])
    end

    # The `$_` each read of it sees in the per-node scope index, which also reaches the operands the evaluator types
    # without entering.
    def indexed_last_line_reads(source)
      program = parse_program(source)
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: default_env_scope)
      reads = []
      program.breadth_first_search do |node|
        reads << index[node].global(:$_) if node.is_a?(Prism::GlobalVariableReadNode) && node.name == :$_
        false
      end
      reads
    end

    it "forgets `$_` where a `case` clause's tests may set it, and in every later operand of a reader" do
      ["case\nwhen gets then 1\nelse $_\nend", "case x\nwhen $stdin.gets then 1\nend\n$_",
       "case x\nin Integer if gets then 1\nelse $_\nend", "bar(gets, $_)", "[gets, $_]", "gets.to_s + $_",
       "show(gets, xs.map { $_ })", "h = { a: gets, b: [1].map { $_ } }", "puts(foo(gets) ? $_ : 0)"].each do |body|
        reads = indexed_last_line_reads("def m(x, xs)\n  if $stdin.gets\n#{body}\n  end\nend\n")
        expect(reads).to all(be_nil), body
        expect(reads).not_to be_empty, body
      end
      expect(indexed_last_line_reads("def m\n  if $stdin.gets\n    [$_, 1]\n  end\nend\n")).to eq([string_t])
      # A statement list, a loop or a conditional runs its parts in order, so a read before the reader keeps it.
      expect(indexed_last_line_reads("def m(ok)\n  if $stdin.gets\n    a = $_\n    b = gets if ok\n  end\nend\n"))
        .to eq([string_t])
      # `&&` and `||` run their operands in order too, so a read in the left operand of one whose right operand
      # reads a line keeps the narrowing, and so does a read in one that reads no line.
      expect(indexed_last_line_reads("def m(ok)\n  if $stdin.gets\n    $_.empty? && gets\n  end\nend\n"))
        .to eq([string_t])
      expect(indexed_last_line_reads("def m(ok)\n  if $stdin.gets\n    $_.empty? || gets\n  end\nend\n"))
        .to eq([string_t])
      expect(indexed_last_line_reads("def m(ok)\n  if $stdin.gets\n    x = (ok && $_)\n  end\nend\n"))
        .to eq([string_t])
    end

    # `redo` re-enters the body without testing the predicate again.
    it "enters a body a `redo` targets without the predicate's narrowing" do
      reads, = last_line_reads("while $stdin.gets\n  $_\n  gets\n  redo if ok\nend\n")
      expect(reads).to all(be_nil)
      reads, = last_line_reads("while $stdin.gets\n  $_\n  redo if ok\nend\n")
      expect(reads).to eq([nil])
      # A body that rebinds a local runs the fixpoint passes, which enter on the predicate's edge.
      reads, = last_line_reads("while $stdin.gets\n  x = $_\n  gets\n  redo if x\nend\n")
      expect(reads).to all(be_nil)
      reads, = last_line_reads("while $stdin.gets\n  x = $_\n  redo if x\nend\n")
      expect(reads.last).to eq(string_t)
    end

    it "joins a reader condition's arms with `$_` unbound" do
      ["if $stdin.gets\n  1\nend", "ok = $stdin.gets ? true : false", "x = (1 if $stdin.gets)"].each do |statement|
        _, post = last_line_reads("#{statement}\n")
        expect(post.global(:$_)).to be_nil, statement
      end
    end

    # The single body pass enters on the predicate's loop-entry edge as the fixpoint passes do, so a body that
    # rebinds no local reads the narrowing too; a `begin … end while` body runs once before the predicate.
    it "enters the single body pass of a loop on the predicate's edge, but not a `begin … end while` body" do
      program = parse_program(<<~RUBY)
        while (line = STDIN.gets)
          line
        end
        begin
          line
        end while (line = STDIN.gets)
      RUBY
      reads = []
      recorder = ->(node, scope) { reads << scope.local(:line) if node.is_a?(Prism::LocalVariableReadNode) }
      described_class.new(scope: default_env_scope, on_enter: recorder).evaluate(program)
      expect(reads.first).to eq(string_t)
      expect(reads.last).to eq(Rigor::Type::Combinator.union(string_t, nil_t))
    end

    it "enters the single pass of a body a `redo` targets from the post-predicate scope" do
      program = parse_program(<<~RUBY)
        while (line = STDIN.gets)
          line
          redo if line.empty?
        end
      RUBY
      reads = []
      recorder = ->(node, scope) { reads << scope.local(:line) if node.is_a?(Prism::LocalVariableReadNode) }
      described_class.new(scope: default_env_scope, on_enter: recorder).evaluate(program)
      expect(reads.first).to eq(Rigor::Type::Combinator.union(string_t, nil_t))
    end
  end

  # See docs/notes/20260615-loop-break-binding-propagation-design.md.
  describe "break-path binding propagation (loop continuation)" do
    def local_after(source, name)
      _, post = evaluate(source)
      post.local(name)
    end

    it "joins a `flag = true; break` binding into a `for` loop continuation" do
      # Pre-fix `flag` typed `false` here (a later `if flag` false-fired always-falsey); the break path's `true` is now
      # joined in.
      flag = local_after(<<~RUBY, :flag)
        flag = false
        for i in [1, 2, 3]
          if i then flag = true; break end
        end
        flag
      RUBY
      expect(flag.describe).to match(/true|bool/i)
    end

    it "joins a `flag = true; break` binding into a `while` loop continuation" do
      flag = local_after(<<~RUBY, :flag)
        flag = false
        i = 0
        while i < 3
          if i then flag = true; break end
          i += 1
        end
        flag
      RUBY
      expect(flag.describe).to match(/true|bool/i)
    end

    it "propagates a break binding written inside a nested loop" do
      found = local_after(<<~RUBY, :found)
        found = false
        for i in [1]
          for j in [1]
            found = true
            break
          end
        end
        found
      RUBY
      expect(found.describe).to match(/true|bool/i)
    end

    it "does NOT pollute the loop local with a break inside a nested block" do
      # `break` inside `each { ... }` targets `each`, not the `while`; its scope must not join the while continuation —
      # `flag` stays false.
      flag = local_after(<<~RUBY, :flag)
        flag = false
        while true
          [1].each { |x| break if x }
          break
        end
        flag
      RUBY
      expect(flag).to eq(Rigor::Type::Combinator.constant_of(false))
    end

    it "does not leak a transient overwritten before the break (no over-widening)" do
      # `out = nil; out = real; break` — the break scope captures the real value, never the transient nil, so `out` is
      # not falsely nilable.
      out = local_after(<<~RUBY, :out)
        out = []
        for i in [1]
          if i
            out = nil
            out = i
            break
          end
        end
        out
      RUBY
      expect(out.describe).not_to match(/\bnil\b/)
    end
  end

  # Issue #1223 — a call's receiver and arguments, a literal, an interpolation and a `rescue` modifier were typed as
  # pure expressions, so a write nested in one left the post-statement scope on the pre-write binding. Each shape pairs
  # with a control that must keep its answer.
  describe "writes inside call operands and literals (issue #1223)" do
    def local_after(source, name)
      _, post = evaluate(source)
      post.local(name)
    end

    def const(value)
      Rigor::Type::Combinator.constant_of(value)
    end

    def union(*values)
      Rigor::Type::Combinator.union(*values.map { |value| const(value) })
    end

    it "threads a compound write in a call's argument" do
      expect(local_after("n = 0\nout = []\nout << (n += 1)\n", :n)).to eq(const(1))
    end

    it "binds a plain write in a call's argument" do
      expect(local_after("puts(m = 5)\n", :m)).to eq(const(5))
    end

    it "threads a write in the receiver" do
      expect(local_after("s = 0\n(s += 1) == 2\n", :s)).to eq(const(1))
    end

    it "threads an index argument, a keyword argument and a splat" do
      expect(local_after("h = {}\ns = 0\nh[s = 1]\n", :s)).to eq(const(1))
      expect(local_after("s = 0\nputs(k: (s = 1))\n", :s)).to eq(const(1))
      expect(local_after("s = 0\nputs(*(s = [1]))\n", :s)).to eq(Rigor::Type::Combinator.tuple_of(const(1)))
    end

    it "threads the operands in evaluation order" do
      expect(local_after("a = 0\nputs(a = 1, a = :b)\n", :a)).to eq(const(:b))
      expect(local_after("a = 0\n(a = 1).then(a = :b)\n", :a)).to eq(const(:b))
    end

    it "threads a write in an array literal and an interpolation, as a statement and as a value" do
      expect(local_after("s = 0\n[s = 1]\n", :s)).to eq(const(1))
      expect(local_after("s = 0\nx = [:a, s += 1]\n", :s)).to eq(const(1))
      expect(local_after("s = 0\n\"\#{s = 1}\"\n", :s)).to eq(const(1))
      expect(local_after("s = 0\nh = { k: (s = 1) }\n", :s)).to eq(const(1))
    end

    it "threads a write in an instance-variable assignment's right-hand side call" do
      expect(local_after("s = 0\n@x = format(\"%d\", s = 1)\n", :s)).to eq(const(1))
    end

    it "threads an instance-variable write in an argument" do
      _, post = evaluate("@v = nil\nputs(@v ||= 1)\n")
      expect(post.ivar(:@v)).to eq(const(1))
    end

    it "joins a `rescue` modifier's arm with the path that did not raise" do
      expect(local_after("s = 0\nx = foo rescue (s = 1)\n", :s)).to eq(union(0, 1))
    end

    it "joins the arguments of a safe-navigation call with the path that skipped them" do
      expect(local_after("s = 0\nr = nil\nr&.foo(s = 1)\n", :s)).to eq(union(0, 1))
    end

    it "widens a loop predicate's write past the one evaluation the walk makes" do
      # Runtime `3`. The pinned `1` met the exit edge `i >= 3` and left `i` as `bot`.
      expect(local_after("i = 0\nwhile (i += 1) < 3\nend\n", :i).describe).to eq("Integer[3..]")
      k = local_after("i = 0\nk = nil\nwhile check(k = i * 2)\n  i += 1\nend\n", :k)
      expect(k).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "carries a write in an argument's block through that call's write-back" do
      expect(local_after("t = 0\nputs([1].each { |x| t = :w })\n", :t)).to eq(union(0, :w))
    end

    it "carries an argument's write into ADR-56's block write-back" do
      expect(local_after("g = :init\n[1, 2].each { |e| puts(g = e) }\n", :g)).to eq(union(:init, 1, 2))
    end

    it "runs the call's own block from the scope after its arguments" do
      expect(local_after("g = nil\nh = nil\n1.upto(g = 2) { |_i| h = g }\n", :h)).to eq(union(nil, 2))
      expect(local_after("g = nil\n1.upto(g = 2) { |_i| g = :z }\n", :g)).to eq(union(2, :z))
      expect(local_after("1.upto(g = 2) { |_i| g = :z }\n", :g)).to eq(union(2, :z))
    end

    it "joins a block-level `next` inside an argument into the block's exit" do
      g = local_after(<<~RUBY, :g)
        g = :init
        [1, 2].each do |e|
          puts((g = e).odd? && next)
          g = :tail
        end
      RUBY
      expect(g).to eq(union(:init, :tail, 1, 2))
    end

    it "joins a block-level `break` inside an argument into the continuation" do
      hit = local_after(<<~RUBY, :hit)
        hit = nil
        [1, 2].each do |e|
          puts((hit = e).even? && break)
          hit = :missed
        end
      RUBY
      expect(hit).to eq(union(nil, :missed, 1, 2))
    end

    context "with operands that write nothing the scope keeps" do
      it "leaves the scope unchanged for an argument that only reads" do
        base = scope.with_local(:m, const(1))
        _, post = evaluate("puts(m + 1)\n", base_scope: base)
        expect(post).to eq(base)
      end

      it "keeps a block-local write in an argument's block out of the outer scope" do
        expect(local_after("puts([1].map { |x| y = x })\n", :y)).to be_nil
      end

      it "does not record a lambda's or a defined method's `return` as the enclosing method's" do
        # `return` inside a lambda returns from the lambda, and inside a `define_method` block from the method it
        # defines; the argument position now evaluates such a body.
        source = "register(-> { return :skip })\ncb = -> { return 1 }\nregister(lambda { return :l })\n" \
                 "self.class.send(:define_method, :m) { return :d }\ndefine_method(:n) { return :e }\n42\n"
        _, sink = described_class.with_return_sink { evaluate(source) }
        expect(sink).to be_empty
      end

      it "keeps a write inside a `def` argument out of the enclosing scope" do
        expect(local_after("private def helper\n  q = 1\nend\n", :q)).to be_nil
      end

      it "types the call's value and its argument's value at the entry scope" do
        type, = evaluate("n = 0\n[n += 1].first\n")
        expect(type).to eq(const(1))
      end
    end
  end

  # An `&&` predicate's truthy edge, and an `||` predicate's falsey edge, is a path on which the right operand ran, so a
  # write in it is certain there; narrowing the joined scope after the operator read such a local as `nil` too. Issue
  # #1223 made the shape common by threading writes nested in a call's operands.
  describe "and/or predicate edges read the scope the right operand left" do
    let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:no) { Rigor::Type::Combinator.constant_of(:no) }
    let(:nil_type) { Rigor::Type::Combinator.constant_of(nil) }
    let(:base) do
      bool = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(true), Rigor::Type::Combinator.constant_of(false)
      )
      scope.with_local(:flag, bool).with_local(:k, integer).with_local(:src, union(integer, nil_type))
    end

    # `flag`, `k` and `src` are bound in `base`; `scopes:` makes Prism parse them as the locals they are.
    def local_after(source, name)
      _, post = base.evaluate(Prism.parse(source, scopes: [%i[flag k src]]).value)
      post.local(name)
    end

    def union(*types)
      Rigor::Type::Combinator.union(*types)
    end

    it "binds a write in an `&&` predicate's right operand on the truthy edge" do
      r = local_after("r = if flag && limit(n = k) then n else :no end\n", :r)
      expect(r).to eq(union(integer, no))
    end

    it "binds a statement-position write in the right operand on the truthy edge" do
      r = local_after("r = if flag && (n = k; flag) then n else :no end\n", :r)
      expect(r).to eq(union(integer, no))
    end

    it "carries the truthy edge into a later `&&` operand" do
      r = local_after("r = if flag && limit(n = k) && n.to_s then n else :no end\n", :r)
      expect(r).to eq(union(integer, no))
    end

    it "binds a write in an `||` predicate's right operand on the falsey edge" do
      r = local_after("r = unless flag || limit(n = k) then n else :no end\n", :r)
      expect(r).to eq(union(integer, no))
    end

    it "keeps the path that skipped the right operand on the other edge" do
      r = local_after("r = if flag && limit(n = k) then :no else n end\n", :r)
      expect(r).to eq(union(no, integer, nil_type))
    end

    # A write's value is the binding it leaves, so a predicate on it narrows the variable like the same
    # predicate on a read of it.
    it "narrows a local written in a predicate's receiver as a read of it" do
      expect(local_after("r = if (v = src).nil? then :no else v end\n", :r)).to eq(union(no, integer))
      expect(local_after("r = if (v = src).nil? || v.zero? then :no else v end\n", :r)).to eq(union(no, integer))
      expect(local_after("v = nil\nr = if (v ||= src).nil? then :no else v end\n", :r)).to eq(union(no, integer))
    end

    it "narrows an instance variable written in a predicate's receiver" do
      source = "r = if (@w = src).nil? then :no else @w end\n"
      _, post = base.evaluate(Prism.parse(source, scopes: [%i[flag k src]]).value)
      expect(post.local(:r)).to eq(union(no, integer))
    end

    it "keeps the nil on the edge where the receiver's value was nil" do
      expect(local_after("r = if (v = src).nil? then v else :no end\n", :r)).to eq(union(nil_type, no))
    end
  end
end
