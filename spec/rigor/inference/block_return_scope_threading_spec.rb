# frozen_string_literal: true

require "spec_helper"

# Block-return typing threads the block body's own bindings (issue #533 item 9).
#
# The block-return pass used to type only the body's LAST statement, in the block's ENTRY scope, so a tail
# reading a name an earlier statement of the same body binds fell through to `Dynamic[top]` — while the main
# pass, which threads scope through `StatementEvaluator`, held the right answer for the very same node.
#
# Every "fires" example below is paired with a "does not fire" control: the threading must not perturb a
# single-statement block, a tail that reads an outer local or a def parameter, or the non-block sequencing
# path (`x = begin … end`), which shares `statements_type_for` with every control-flow body handler and is
# deliberately left alone.
RSpec.describe "block-return scope threading", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # `dumped_types(...).first` is only the FIRST dump in the fixture, so a source that accidentally grows a
  # second `dump_type` would have its extra answer silently dropped. Every fixture here is written with
  # exactly one; "reports exactly one dump per fixture" below is the assertion that keeps it honest.
  def dumped_type(source) = dumped_types(source).first

  # Every diagnostic a flow rule produced for `source` — the always-truthy / always-falsey family.
  def flow_rules(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
  end

  # Every `call.undefined-method` diagnostic `source` produced — what a receiver a stale fold proved nil reports.
  def undefined_method_rules(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s == "call.undefined-method" }
  end

  describe "the tail reads a name the body binds" do
    it "types a block-local tail through a generic block-return signature" do
      # The reported repro: `Mutex#synchronize` is `[X] () { () -> X } -> X`, so the block's return type IS
      # the call's type. Before the fix `X` bound to `Dynamic[top]`.
      expect(dumped_type(<<~RUBY)).to eq("42")
        m = Mutex.new
        r = m.synchronize do
          v = 42
          v
        end
        dump_type(r)
      RUBY
    end

    it "types a block-local tail per element under the Tuple map fold" do
      expect(dumped_type(<<~RUBY)).to eq("[42, 42]")
        dump_type([1, 2].map do
          q = 42
          q
        end)
      RUBY
    end

    it "threads a transitive chain of block-local bindings" do
      expect(dumped_type(<<~RUBY)).to eq("2")
        m = Mutex.new
        dump_type(m.synchronize do
          a = 1
          b = a + 1
          b
        end)
      RUBY
    end

    it "joins both arms of a conditional binding" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2")
        m = Mutex.new
        flag = [true, false].sample
        dump_type(m.synchronize do
          v = (flag ? 1 : 2)
          v
        end)
      RUBY
    end

    it "takes the last binding when the body rebinds the name" do
      expect(dumped_type(<<~RUBY)).to eq("\"s\"")
        m = Mutex.new
        dump_type(m.synchronize do
          c = 1
          c = "s"
          c
        end)
      RUBY
    end

    it "threads an instance-variable tail, not only locals" do
      expect(dumped_type(<<~RUBY)).to eq("42")
        class Holder
          def initialize
            @m = Mutex.new
            @iv = nil
          end

          def run
            dump_type(@m.synchronize do
              @iv = 42
              @iv
            end)
          end
        end
      RUBY
    end
  end

  describe "control-flow semantics are unchanged" do
    it "leaves an early `return` out of the block's value" do
      # The `return` exits the enclosing METHOD; the block's value is still the fall-through tail. A
      # regression here would surface as `42 | 7` (the return joined into the block return) or `Dynamic[top]`.
      expect(dumped_type(<<~RUBY)).to eq("42")
        def run(flag)
          m = Mutex.new
          dump_type(m.synchronize do
            return 7 if flag
            v = 42
            v
          end)
        end
      RUBY
    end

    it "keeps a content-mutated collection sound rather than folding the literal seed" do
      # The FP-relevant half of the fix: a naive prefix fold would answer the empty `Tuple[]` here (runtime
      # `[1]`) and hand downstream rules a provably-empty array. Reusing `StatementEvaluator` keeps the
      # ADR-56 / mutation-widening treatment, so the answer widens instead.
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        dump_type(m.synchronize do
          arr = []
          arr << 1
          arr
        end)
      RUBY
      expect(type).to start_with("Array[")
      expect(type).not_to eq("[]")
    end
  end

  # PR #584 review — a `next` / `break` in a statement BEFORE the tail leaves the block carrying a value the
  # fold never sees: `evaluate(body).first` is the fall-through value only. Threading such a body reports the
  # fall-through as if it were the whole answer, which is the one way this change could invent a false
  # positive rather than merely widen. The fold declined instead, which was master's answer for every shape
  # here. Issue #841 answered the `next` half properly — the arms now JOIN — so only `break` still declines.
  describe "a prefix that can jump out of the block" do
    it "joins a value-carrying `next` before the tail into the block's value" do
      # WAS THE BLOCKER, now the fix. `next 5` makes the block's value 5 for that yield, and
      # `Mutex#synchronize` is `[X] () { () -> X } -> X`, so the CALL answers 5 or 42. Typing it `42` was
      # unsound and the fold declined to `Dynamic[top]`; the join says both.
      expect(dumped_type(<<~RUBY)).to eq("42 | 5")
        m = Mutex.new
        flag = [true, false].sample
        dump_type(m.synchronize do
          next 5 if flag
          v = 42
          v
        end)
      RUBY
    end

    it "still declines on a value-carrying `break` before the tail, which the call's own union covers" do
      # `break` terminates the YIELDING CALL and makes it answer 5, so the threading fold's `42` was as
      # unsound here as it is for `next`, and it declines. Issue #853 supplies the 5 from the other end — the
      # call unions its `break` arms — so the decline is no longer what keeps this sound; it is conservative,
      # and its remaining cost is the threaded tail, `Dynamic[top]` where threading would reach `42`. Lifting
      # it moves the type of every block carrying a `break`, so it wants a change that can measure that.
      expect(dumped_type(<<~RUBY)).to eq("5 | Dynamic[top]")
        m = Mutex.new
        flag = [true, false].sample
        dump_type(m.synchronize do
          break 5 if flag
          v = 42
          v
        end)
      RUBY
    end

    it "still threads when the `next` belongs to a nested block" do
      # The boundary control, and the reason the prefix walk is not a plain DFS: `next` inside `each`'s block
      # ends THAT iteration and cannot carry a value out of the outer block, so declining here would cost
      # precision for nothing.
      expect(dumped_type(<<~RUBY)).to eq("42")
        m = Mutex.new
        dump_type(m.synchronize do
          [1, 2].each { next 1 }
          v = 42
          v
        end)
      RUBY
    end

    it "still threads when the `next` belongs to a loop" do
      # A loop consumes both jump forms — `next` continues it, `break` leaves it — so neither reaches the
      # block. Same boundary rule as the nested-block case above.
      expect(dumped_type(<<~RUBY)).to eq("42")
        m = Mutex.new
        flag = [true, false].sample
        dump_type(m.synchronize do
          while flag
            next 5
          end
          v = 42
          v
        end)
      RUBY
    end

    it "still threads when the `next` belongs to a lambda" do
      expect(dumped_type(<<~RUBY)).to eq("42")
        m = Mutex.new
        dump_type(m.synchronize do
          fn = -> { next 1 }
          v = 42
          v
        end)
      RUBY
    end
  end

  # Issue #587 (a) — the gate was blind to CONTENT mutation. `push` is a call, not a variable-write node, so a
  # prefix that only mutates a captured collection in place collected no written name, the fold declined, and
  # the tail kept the entry scope's literal: `[]` for a block whose runtime value is `[1]`. Threading is the
  # fix rather than a cost — `StatementEvaluator` widens the receiver at the mutator call, so the threaded
  # tail reads the honest `Array[…]`. The gate now also fires on a receiver of any name the widening responds
  # to (`MutationWidening::SHAPE_MUTATORS`), through every variable the receiver can evaluate to.
  describe "a prefix that mutates a captured collection in place" do
    it "threads through a content adder on a captured local" do
      # THE ISSUE'S PROBE. Before the fix this answered `[]`.
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        outer = []
        dump_type(m.synchronize do
          outer.push(1)
          outer
        end)
      RUBY
      expect(type).to start_with("Array[")
      expect(type).not_to eq("[]")
    end

    it "threads through a remover, whose widening forgets the literal arity" do
      # `pop` adds no element evidence, so the widened carrier keeps the seed's value pinning; what it must
      # not keep is the `Tuple[1]` arity a `.empty?` fold would read as provably non-empty.
      expect(dumped_type(<<~RUBY)).to eq("Array[1]")
        m = Mutex.new
        outer = [1]
        dump_type(m.synchronize do
          outer.pop
          outer
        end)
      RUBY
    end

    it "threads through a hash store" do
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        outer = {}
        dump_type(m.synchronize do
          outer[:a] = 1
          outer
        end)
      RUBY
      expect(type).to start_with("Hash[")
      expect(type).not_to eq("{}")
    end

    # The index-write forms store through `[]=` without being a `[]=` call: Prism gives `h[k] += v`,
    # `h[k] ||= v`, `h[k] &&= v` and a multi-assign `h[k], x = …` target their own node classes, so a scan
    # keyed on call names saw none of them and the tail read the entry literal's slot.
    it "threads through a compound index write" do
      # THE REPORTED PROBE. Before the fix `v` read the literal's `0`, and `v == 0` folded to always-truthy
      # on a program whose runtime `v` is `1`.
      expect(flow_rules(<<~RUBY)).to be_empty
        m = Mutex.new
        h = { a: 0 }
        v = m.synchronize do
          h[:a] += 1
          h[:a]
        end
        puts "one" if v == 0
      RUBY
    end

    it "still reports the condition when the index write lands on another hash" do
      # The must-fire control: the tail reads `h`, which the prefix never touches, so its `0` is still the
      # truth and the condition genuinely always holds.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        m = Mutex.new
        g = { a: 0 }
        h = { a: 0 }
        v = m.synchronize do
          g[:a] += 1
          h[:a]
        end
        puts "one" if v == 0
      RUBY
    end

    it "threads through an or-assigning index write" do
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        h = { a: 0 }
        dump_type(m.synchronize do
          h[:b] ||= 1
          h
        end)
      RUBY
      expect(type).to start_with("Hash[")
    end

    it "threads through an and-assigning index write" do
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        h = { a: 1 }
        dump_type(m.synchronize do
          h[:a] &&= 2
          h
        end)
      RUBY
      expect(type).to start_with("Hash[")
    end

    it "threads through a multi-assign index target inside a nested block" do
      # The captured-local write-back widens a receiver stored into through an `IndexTargetNode`, so the
      # nested `each` really does forget `h`'s literal — once the gate lets the body thread.
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        h = { a: 0 }
        dump_type(m.synchronize do
          [1].each { |e| h[:a], _w = e, 2 }
          h
        end)
      RUBY
      expect(type).to start_with("Hash[")
    end

    it "leaves a tail reading a hash the index write does not touch unchanged" do
      expect(dumped_type(<<~RUBY)).to eq("{ a: 0 }")
        m = Mutex.new
        g = { a: 0 }
        h = { a: 0 }
        dump_type(m.synchronize do
          g[:a] += 1
          h
        end)
      RUBY
    end

    it "threads through an adder on a selected receiver" do
      # The issue #277 receiver shape: the mutation lands on whichever of `a` / `b` the ternary picked, so
      # both are possible targets and a tail reading either must thread.
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        flag = [true, false].sample
        a = []
        b = []
        dump_type(m.synchronize do
          (flag ? a : b) << 1
          a
        end)
      RUBY
      expect(type).to start_with("Array[")
    end

    it "threads through an adder inside a nested block" do
      # A block is a closure, so the nested `each`'s `<<` really does mutate the outer `outer` — the scan
      # collects it at any depth, exactly as it collects a nested variable write.
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        outer = []
        dump_type(m.synchronize do
          [1].each { |e| outer << e }
          outer
        end)
      RUBY
      expect(type).to start_with("Array[")
    end

    it "threads through a straight-line multi-assign index target" do
      # `h[:a], y = 1, 2` stores through `[]=` on `h`. The prefix scan counts the index target as an in-place
      # mutation, so the body threads, and `eval_multi_write` widens the receiver, so the threaded tail reads the
      # widened hash rather than the literal's `{ a: 0 }`. Either half alone leaves the literal.
      type = dumped_type(<<~RUBY)
        m = Mutex.new
        h = { a: 0 }
        dump_type(m.synchronize do
          h[:a], y = 1, 2
          h
        end)
      RUBY
      expect(type).to start_with("Hash[")
    end

    it "leaves a tail reading a hash the multi-assign does not store into at its literal" do
      expect(dumped_type(<<~RUBY)).to eq("{ a: 0 }")
        m = Mutex.new
        g = { a: 0 }
        h = { a: 0 }
        dump_type(m.synchronize do
          g[:a], y = 1, 2
          h
        end)
      RUBY
    end

    it "threads a mutated block parameter at every per-element position" do
      type = dumped_type(<<~RUBY)
        dump_type([[], []].map do |a|
          a << 1
          a
        end)
      RUBY
      expect(type).to match(/\A\[Array\[.*\], Array\[.*\]\]\z/)
    end

    it "leaves a tail reading an unmutated captured local unchanged" do
      # The control: `b` is never mutated, so its literal is still the truth and the answer must not move.
      expect(dumped_type(<<~RUBY)).to eq("[]")
        m = Mutex.new
        a = []
        b = []
        dump_type(m.synchronize do
          a << 1
          b
        end)
      RUBY
    end

    # The receiver scan collected only local and instance-variable reads, so a global or class variable the prefix
    # mutated in place did not make the body thread, and the tail kept the entry binding. The straight-line
    # widening the threaded body runs had the same blind spot, so threading alone would not have moved it either.
    it "threads through an append to a global" do
      # THE REPORTED PROBE. Runtime `r` is `"k1"`; `r == "k"` folded to always-truthy.
      expect(flow_rules(<<~RUBY)).to be_empty
        $g = +"k"
        m = Mutex.new
        v = 1
        r = m.synchronize { $g << v.to_s; $g }
        puts "same" if r == "k"
      RUBY
    end

    it "still reports the condition when the append lands on another global" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        $g = +"k"
        $h = +"k"
        m = Mutex.new
        v = 1
        r = m.synchronize { $h << v.to_s; $g }
        puts "same" if r == "k"
      RUBY
    end

    it "threads through an append to a class variable" do
      expect(flow_rules(<<~RUBY)).to be_empty
        class Buf
          def run(v)
            @@out = +"k"
            m = Mutex.new
            r = m.synchronize { @@out << v.to_s; @@out }
            puts "same" if r == "k"
          end
        end
      RUBY
    end

    it "still reports the condition when the append lands on another class variable" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        class Buf
          def run(v)
            @@out = +"k"
            @@log = +"k"
            m = Mutex.new
            r = m.synchronize { @@log << v.to_s; @@out }
            puts "same" if r == "k"
          end
        end
      RUBY
    end

    it "threads through a compound index write on a global" do
      expect(flow_rules(<<~RUBY)).to be_empty
        $h = { a: 0 }
        m = Mutex.new
        v = m.synchronize do
          $h[:a] += 1
          $h[:a]
        end
        puts "one" if v == 0
      RUBY
    end

    it "still reports the condition when the index write lands on another global" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        $g = { a: 0 }
        $h = { a: 0 }
        m = Mutex.new
        v = m.synchronize do
          $g[:a] += 1
          $h[:a]
        end
        puts "one" if v == 0
      RUBY
    end

    # `it` reads are `Prism::ItLocalVariableReadNode`, which carries no `name`: neither the tail's read set nor the
    # receiver scan saw it, and the straight-line widening skipped it as a receiver, so the body typed from its
    # entry element while the `|a|` spelling above widened.
    it "threads a mutated `it` parameter at every per-element position, as it threads `|a|`" do
      # Runtime `[[1], [1]]`; the fold answered `[[], []]`. The joined `Integer` is the pushed evidence, which the
      # widening reads only when it knows the receiver names a carrier it will grow.
      expected = "[Array[Dynamic[top] | Integer], Array[Dynamic[top] | Integer]]"
      expect(dumped_type(<<~RUBY)).to eq(expected)
        dump_type([[], []].map do
          it << 1
          it
        end)
      RUBY
      expect(dumped_type(<<~RUBY)).to eq(expected)
        dump_type([[], []].map do |a|
          a << 1
          a
        end)
      RUBY
    end

    it "leaves a tail that ignores the mutated `it` parameter unchanged" do
      # A must-hold check rather than a control for the `it` naming: `b` is untouched on every path.
      expect(dumped_type(<<~RUBY)).to eq("[[], []]")
        b = []
        dump_type([[], []].map do
          it << 1
          b
        end)
      RUBY
    end

    it "joins a value-carrying `next` ahead of the mutation with the widened tail" do
      # The two mechanisms compose. Before issue #841 the jump made the fold decline and the tail kept the
      # entry literal `[]` — no better than the runtime value (`[1]` or `5`). The join runs the same threaded
      # evaluation, so the mutated tail widens AND the escaping arm is there.
      expect(dumped_type(<<~RUBY)).to eq("5 | Array[Dynamic[top] | Integer]")
        m = Mutex.new
        flag = [true, false].sample
        outer = []
        dump_type(m.synchronize do
          next 5 if flag
          outer.push(1)
          outer
        end)
      RUBY
    end
  end

  # Issue #587 (b) — first-iteration pinning. The per-element Tuple fold typed every position from the same
  # entry scope, so a body that rebinds a captured outer local answered the FIRST iteration's value at every
  # position: `[1, 1]` for a block whose runtime values are `[1, 2]`, and `r.first == 1` then folded to
  # `true`. The fold now runs the ADR-56 `BodyFixpoint` over the rebound names up front and types every
  # position with them bound to the converged (widened) type — what the local can be in ANY iteration.
  describe "captured outer locals the body rebinds under the per-element fold" do
    it "widens a rebound counter to its continuation binding at every position" do
      # THE ISSUE'S PROBE. Before the fix this answered `[1, 1]` (and `[0, 0]` before #584 — a pin either way).
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        total = 0
        dump_type([1, 2].map do
          total += 1
          total
        end)
      RUBY
    end

    it "no longer reports the condition the first-iteration pin used to fold" do
      # THE HAZARD: `r.first == 1` folded to `Constant[true]` off `[1, 1]` and fired on correct code.
      expect(flow_rules(<<~RUBY)).to be_empty
        total = 0
        r = [1, 2].map do
          total += 1
          total
        end
        puts "x" if r.first == 1
      RUBY
    end

    it "still reports the condition when the fold is exact" do
      # The must-fire sibling: a body that rebinds nothing keeps its exact per-position values, so the same
      # condition on `[1, 2]` is genuinely always true and the rule must keep saying so.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        r = [1, 2].map { |e| e }
        puts "x" if r.first == 1
      RUBY
    end

    it "widens an accumulator fed by the block parameter" do
      # `[1, 3]` at runtime; the pin answered `[1, 2]`, the element itself.
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        total = 0
        dump_type([1, 2].map do |e|
          total += e
          total
        end)
      RUBY
    end

    it "floors a structurally compounding rebind instead of pinning the first shape" do
      # `x = [x]` never converges (`[1]`, `[[1]]`, …), so the fixpoint floors `x` to `Dynamic[top]` and every
      # position reads a one-element Tuple of it — which `[[1], [[1]]]` really is. The pin answered `[[1], [1]]`.
      expect(dumped_type(<<~RUBY)).to eq("[[Dynamic[top]], [Dynamic[top]]]")
        x = 1
        dump_type([1, 2].map do
          x = [x]
          x
        end)
      RUBY
    end

    it "keeps a position whose tail reads a captured local the body does not rebind" do
      # Only the rebound names move; `k` is untouched and its literal is still the truth at every position.
      expect(dumped_type(<<~RUBY)).to eq("[5, 5]")
        total = 0
        k = 5
        dump_type([1, 2].map do |e|
          total += e
          k
        end)
      RUBY
    end

    it "keeps a predicate fold that ignores the rebound counter" do
      # The reason this is not a blanket decline: `e > 1` decides on the element alone, so the `select` fold
      # still knows exactly which positions survive.
      expect(dumped_type(<<~RUBY)).to eq("[2]")
        seen = 0
        dump_type([1, 2].select do |e|
          seen += 1
          e > 1
        end)
      RUBY
    end

    it "keeps the optimistic nil-freeness mark on a rebound local" do
      # `xs.first` reads nil-free only because RBS dispatch reads past `%a{implicitly-returns-nil}`, and the
      # local carries that mark so `v.nil?` stays undecided. Rebinding the local for the fold must carry the
      # mark too, or every position folds `v.nil?` to `false`; at runtime `r` is `[false, false]`.
      expect(dumped_type(<<~RUBY)).to eq("[bool, bool]")
        xs = Array.new(rand(0)) { |i| i }
        v = xs.first
        dump_type([1, 2].map do |e|
          out = v.nil? ? false : true
          v = xs.first
          out
        end)
      RUBY
    end

    it "still widens past the per-element threading cap" do
      # The fixpoint binds the parameter to the union of the elements, so its cost does not scale with the
      # arity and the cap is no reason to keep the stale seed: nine positions read `Integer`, not `0`.
      expect(dumped_type(<<~RUBY)).to eq("[#{(['Integer'] * 9).join(', ')}]")
        total = 0
        dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
          total += e
          total
        end)
      RUBY
    end

    it "floors the rebound local when the fold is nested inside a threaded body" do
      # The fold is not re-entrant: under threading suppression the fixpoint's body evaluations are refused
      # and the rebound name takes the escaping-block floor — wider than `Integer`, but no longer the `[0, 0]`
      # pin the nested fold answered before.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
        m = Mutex.new
        total = 0
        dump_type(m.synchronize do
          v = 1
          [1, 2].map do
            total += v
            total
          end
        end)
      RUBY
    end
  end

  # The shapes the #587 (a) gate newly threads. Once an index write in the prefix threads the body, each
  # position of the per-element fold stored its OWN element through `||=` into the empty entry hash, where
  # Ruby keeps the first iteration's — unless the in-place widening below binds the captured carrier first.
  # A mutator NAME on a value it does not move (an Integer shift, a String copy) must stay exact.
  describe "index writes the #587 (a) gate threads under the per-element fold" do
    it "does not pin a captured hash an or-assigning index write fills" do
      # THE HAZARD: the second position answered `2 == 2`, so `find` folded to `2` (runtime `nil`) and
      # `found == 2` reported always-truthy.
      expect(flow_rules(<<~RUBY)).to be_empty
        cache = {}
        found = [1, 2].find do |e|
          cache[:first] ||= e
          cache[:first] == 2
        end
        puts "hit" if found == 2
      RUBY
    end

    it "answers element-or-nil for the same find" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        cache = {}
        dump_type([1, 2].find do |e|
          cache[:first] ||= e
          cache[:first] == 2
        end)
      RUBY
    end

    it "does not pin the same hash under a Range receiver" do
      # Runtime `[1, 1]`; the pin answered `[1, 2]`, and `r.last == 2` folded always-truthy.
      expect(flow_rules(<<~RUBY)).to be_empty
        cache = {}
        r = (1..2).map do |e|
          cache[:k] ||= e
          cache[:k]
        end
        puts "x" if r.last == 2
      RUBY
    end

    it "does not pin an instance-variable hash either" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        class Memo
          def run
            @cache = {}
            dump_type([1, 2].find do |e|
              @cache[:first] ||= e
              @cache[:first] == 2
            end)
          end
        end
      RUBY
    end

    it "keeps a position whose tail ignores the collection it mutates" do
      # The control: `log` joins the fixpoint, but the tail reads only the element, so the fold stays exact.
      expect(dumped_type(<<~RUBY)).to eq("[1, 2]")
        log = []
        dump_type([1, 2].map do |e|
          log << e
          e
        end)
      RUBY
    end

    it "keeps an Integer shift exact although `<<` is a mutator name" do
      # `base` never moves, so admitting it would hand its value-pinned seed to the unmoved-pin floor and
      # answer `Dynamic[top]` at every position.
      expect(dumped_type(<<~RUBY)).to eq("[1, 2, 4]")
        base = 1
        dump_type([0, 1, 2].map { |i| base << i })
      RUBY
    end

    it "keeps a non-mutating String call exact although `delete` is a mutator name" do
      expect(dumped_type(<<~RUBY)).to eq('["heo", "heo"]')
        word = "hello"
        dump_type([1, 2].map { |e| word.delete("l") })
      RUBY
    end

    it "does not pin a captured hash the per-pair transform_values fold fills" do
      # The per-pair fold shares the fixpoint: runtime `{ x: 1, y: 1 }`, and the pin answered `{ x: 1, y: 2 }`
      # so `r[:y] == 2` folded always-truthy.
      expect(flow_rules(<<~RUBY)).to be_empty
        cache = {}
        r = { x: 1, y: 2 }.transform_values do |v|
          cache[:first] ||= v
          cache[:first]
        end
        puts "y" if r[:y] == 2
      RUBY
    end

    it "does not pin a captured hash the per-pair transform_keys fold fills" do
      # Runtime `{ "a" => 2 }` — both keys collide on the first iteration's `"a"` — and the pin answered two
      # distinct keys, so `t.keys.size == 2` folded always-truthy.
      expect(flow_rules(<<~RUBY)).to be_empty
        first = {}
        t = { a: 1, b: 2 }.transform_keys do |k|
          first[:k] ||= k.to_s
          first[:k]
        end
        puts "k" if t.keys.size == 2
      RUBY
    end
  end

  # The one-statement form of the probe above. The in-place widening binds `cache` to `Hash[Dynamic[top],
  # Dynamic[top]]` at every position, so the slot reads wholly gradual, and the value-position `||=` read that as
  # the memoization idiom's "no evidence about the slot" (issue #1202): each position answered its OWN `e`. A
  # block-return pass now marks every such site an earlier run may have filled (`RepeatedOrWrites`), whatever the
  # receiver; a site on a fresh receiver, one whose key differs at every position, and an isolated site under the
  # generic pass keep the memo reading.
  describe "a memoizing index `||=` as a repeating block's whole predicate" do
    def nil_receiver_rules(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      rules = result.diagnostics.map(&:rule)
      rules.select { |rule| rule.to_s == "call.possible-nil-receiver" }
    end

    it "does not pin a captured hash the one-statement `||=` fills" do
      # THE REPORTED PROBE: Ruby keeps the first iteration's `1`, so `find` answers `nil`; the pin answered `2 == 2`
      # at the second position, folded `find` to `2`, and reported `found == 2` always-truthy.
      expect(flow_rules(<<~RUBY)).to be_empty
        cache = {}
        found = [1, 2].find { |e| (cache[:first] ||= e) == 2 }
        puts "hit" if found == 2
      RUBY
    end

    it "answers element-or-nil for the same find" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        cache = {}
        dump_type([1, 2].find { |e| (cache[:first] ||= e) == 2 })
      RUBY
    end

    it "keeps an earlier position's store in a `map` over the same `||=`" do
      # Runtime `[1, 1]`; the pin answered `[1, 2]`. The first position has no earlier one, so it stays exact.
      expect(dumped_type(<<~RUBY)).to eq("[1, 2 | Dynamic[top]]")
        cache = {}
        dump_type([1, 2].map { |e| cache[:first] ||= e })
      RUBY
    end

    it "still fires on a memo hash the block builds afresh at every position (control)" do
      # The fold is exact here: every position's `Hash.new` is empty, so Ruby answers `2 == 2` at the second one,
      # `find` returns `2`, and `found == 2` is always true. A `.new` receiver is fresh at every run, so the site
      # keeps the memo reading.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        found = [1, 2].find { |e| (Hash.new[:first] ||= e) == 2 }
        puts "hit" if found == 2
      RUBY
    end

    it "still fires on a memo hash a block-local holds afresh at every position (control)" do
      # `c` is bound only by the body and only to a new hash, so no position sees another's store: Ruby answers `2`.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        found = [1, 2].find { |e| c = Hash.new; (c[:first] ||= e) == 2 }
        puts "hit" if found == 2
      RUBY
    end

    it "does not take a block-local for fresh below its own slots" do
      # `box` is new at every position, but `box[0]` is `shared`, which the first position filled. Runtime `nil`.
      expect(flow_rules(<<~RUBY)).to be_empty
        shared = Hash.new
        found = [1, 2].find do |e|
          box = [shared]
          (box[0][:first] ||= e) == 2
        end
        puts "hit" if found == 2
      RUBY
    end

    it "answers wider than Ruby when the body rebinds the captured name to a fresh hash first" do
      # Ruby answers `2`: every position's `||=` reads a new hash. The mark belongs to the site, not to the
      # binding, so the rebind does not lift it. Wider, never narrower: nothing is reported.
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        cache = {}
        dump_type([1, 2].find do |e|
          cache = Hash.new
          (cache[:first] ||= e) == 2
        end)
      RUBY
    end

    it "does not pin a captured `Hash.new` the widening leaves where it is" do
      # A bare `Hash` is a nominal the in-place widening declines, so no binding moves; the body still stores
      # into it at every position.
      expect(flow_rules(<<~RUBY)).to be_empty
        cache = Hash.new
        found = [1, 2].find { |e| (cache[:first] ||= e) == 2 }
        puts "hit" if found == 2
      RUBY
    end

    it "does not pin a captured array slot" do
      expect(flow_rules(<<~RUBY)).to be_empty
        slots = []
        found = [1, 2].find { |e| (slots[0] ||= e) == 2 }
        puts "hit" if found == 2
      RUBY
    end

    it "does not pin the same hash under a Range receiver" do
      expect(flow_rules(<<~RUBY)).to be_empty
        cache = {}
        found = (1..2).find { |e| (cache[:first] ||= e) == 2 }
        puts "hit" if found == 2
      RUBY
    end

    it "does not pin a captured hash the per-pair transform_values fold fills" do
      # Runtime `{ x: 1, y: 1 }`; the pin answered `{ x: 1, y: 2 }`, so `r[:y] == 2` folded always-truthy.
      expect(flow_rules(<<~RUBY)).to be_empty
        cache = {}
        r = { x: 1, y: 2 }.transform_values { |v| cache[:first] ||= v }
        puts "y" if r[:y] == 2
      RUBY
    end

    it "does not pin the slot when a narrowing rebinds the receiver's name" do
      # `c &&` narrows `c`, which rebinds it; a mark kept on the binding was dropped with it.
      expect(flow_rules(<<~RUBY)).to be_empty
        c = {}
        found = [1, 2].find { |e| c && (c[:first] ||= e) == 2 }
        puts "hit" if found == 2
      RUBY
    end

    describe "whatever the receiver" do
      it "does not pin an instance-variable hash the method assigns" do
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          class Memo
            def run
              @cache = {}
              dump_type([1, 2].find { |e| (@cache[:first] ||= e) == 2 })
            end
          end
        RUBY
      end

      it "does not pin an instance-variable hash another method assigns" do
        # The ADR-58 declaration seed is no binding the fold widens, but its slot reads a lone `Dynamic` all the same.
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          class Memo
            def initialize = @cache = {}

            def run
              dump_type([1, 2].find { |e| (@cache[:first] ||= e) == 2 })
            end
          end
        RUBY
      end

      it "does not pin a constant hash" do
        expect(flow_rules(<<~RUBY)).to be_empty
          CACHE = {}
          found = [1, 2].find { |e| (CACHE[:first] ||= e) == 2 }
          puts "hit" if found == 2
        RUBY
      end

      it "does not pin a hash an attribute reader returns" do
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          class Memo
            attr_reader :cache

            def initialize = @cache = {}

            def run
              dump_type([1, 2].find { |e| (cache[:first] ||= e) == 2 })
            end
          end
        RUBY
      end

      it "does not pin the inner slot of a nested memo" do
        expect(flow_rules(<<~RUBY)).to be_empty
          cache = {}
          found = [1, 2].find { |e| ((cache[:a] ||= {})[:b] ||= e) == 2 }
          puts "hit" if found == 2
        RUBY
      end
    end

    describe "a key that differs at every position" do
      it "keeps the memo reading, since no position reads another's slot" do
        # Ruby stores each position under its own key, so `find` answers `"b"`, never nil. Withholding the reading
        # here answered `"a" | "b" | nil` and reported `f.upcase` as a possible nil receiver.
        source = <<~RUBY
          pool = {}
          f = %w[a b].find { |s| (pool[s] ||= s) == "b" }
          dump_type(f)
          puts f.upcase
        RUBY
        expect([dumped_type(source), nil_receiver_rules(source)]).to eq(['"b"', []])
      end

      it "withholds it only at the position whose key an earlier one shares" do
        # Runtime `"b"`: the second position reads the `"a"` the first stored, and the third finds `"b"`. Marking every
        # position answered `"a" | "b" | nil` and reported `f.upcase` as a possible nil receiver.
        source = <<~RUBY
          seen = {}
          f = %w[a a b].find { |s| (seen[s] ||= s) == "b" }
          dump_type(f)
          puts f.upcase
        RUBY
        expect([dumped_type(source), nil_receiver_rules(source)]).to eq(['"a" | "b"', []])
      end

      it "keeps it for a key built from a captured local the body leaves alone" do
        expect(dumped_type(<<~RUBY)).to eq('"b"')
          pool = {}
          prefix = "x"
          dump_type(%w[a b].find { |k| (pool[prefix + k] ||= k) == "b" })
        RUBY
      end

      it "keeps it for negative and mixed-class keys on a core Hash" do
        expect(dumped_types(<<~RUBY)).to eq(["-2", '"b"'])
          h = {}
          dump_type([-1, -2].find { |i| (h[i] ||= i) == -2 })
          g = {}
          dump_type([:a, "b"].find { |k| (g[k] ||= k) == "b" })
        RUBY
      end

      it "withholds it for a negative index on a receiver that may be an Array" do
        # `a` is untyped, so `a[-1]` may name the slot `a[1]` names: `pick(Array.new(2))` answers `nil`.
        expect(dumped_type(<<~RUBY)).to eq("[-1, :x] | [1, :y] | nil")
          def pick(a) = dump_type([[-1, :x], [1, :y]].find { |i, v| (a[i] ||= v) == :y })
        RUBY
      end

      it "withholds it for keys of two classes on a receiver that may normalise them" do
        # With indifferent access `:a` and `"a"` name one slot, so the second position keeps the first's `1`.
        expect(dumped_type(<<~RUBY)).to eq('["a", 2] | [:a, 1] | nil')
          class IndifferentHash < Hash
            def [](key)
              super(key.to_s)
            end

            def []=(key, value)
              super(key.to_s, value)
            end
          end
          h = IndifferentHash.new
          dump_type([[:a, 1], ["a", 2]].find { |k, v| (h[k] ||= v) == 2 })
        RUBY
      end

      it "withholds it for a key the body rebinds" do
        # `s = "k"` makes every position's key `"k"`, whatever the parameter held.
        expect(dumped_type(<<~RUBY)).to eq('["a", 1] | ["b", 2] | nil')
          pool = {}
          dump_type([["a", 1], ["b", 2]].find { |s, n| s = "k"; (pool[s] ||= n) == 2 })
        RUBY
      end

      it "types a distinct-key memo under the Tuple, Range and per-pair folds" do
        expect(dumped_types(<<~RUBY)).to eq(['["A", "B"]', "[1, 4, 9]", "{ a: 10, b: 20 }"])
          pool = {}
          dump_type(%w[a b].map { |s| pool[s] ||= s.upcase })
          squares = {}
          dump_type((1..3).map { |i| squares[i] ||= i * i })
          memo = {}
          dump_type({ a: 1, b: 2 }.transform_values { |v| memo[v] ||= v * 10 })
        RUBY
      end

      it "still withholds the reading for a key two positions share" do
        # Runtime `[1, 1]`: the second position reads the `:k` slot the first one filled.
        expect(dumped_type(<<~RUBY)).to eq("[1, 2 | Dynamic[top]]")
          c = {}
          dump_type([[:k, 1], [:k, 2]].map { |k, v| c[k] ||= v })
        RUBY
      end

      it "still withholds the reading when another store in the body can fill the slot" do
        # Runtime `nil`: the first position stores `"x"` under `"b"` after its own `||=`, and the second position's
        # `||=` then keeps that `"x"`. The store comes second, so no threaded write narrows the slot first.
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = {}
          found = %w[a b].find do |s|
            hit = (pool[s] ||= s) == "b"
            pool["b"] = "x"
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end

      it "keeps it beside a store into another instance variable" do
        # `@log << s` reaches `@log`, never `@pool`, although neither is a binding the fold widens.
        expect(dumped_type(<<~RUBY)).to eq('"b"')
          class Registry
            def initialize
              @log = []
              @pool = {}
            end

            def run = dump_type(%w[a b].find { |s| @log << s; (@pool[s] ||= s) == "b" })
          end
        RUBY
      end

      it "withholds it when the body stores through `send`" do
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = Hash.new
          found = %w[a b].find do |s|
            hit = (pool[s] ||= s) == "b"
            pool.send(:[]=, "b", "x")
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end

      it "withholds it when the body rebinds the receiver to another hash" do
        # Runtime `nil`: the second position reads `other`, whose `"b"` is `"x"`.
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = Hash.new
          other = { "b" => "x" }
          found = %w[a b].find do |s|
            hit = (pool[s] ||= s) == "b"
            pool = other
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end

      it "withholds it when a nested block's parameter may name the receiver" do
        # Each block parameter holds `pool` at runtime, so each store puts `"x"` under `"b"`: every `find` answers nil.
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = Hash.new
          a = %w[a b].find { |s| hit = (pool[s] ||= s) == "b"; pool.tap { |h| h["b"] = "x" }; hit }
          b = %w[a b].find { |s| hit = (pool[s] ||= s) == "b"; [pool].each { it["b"] = "x" }; hit }
          c = %w[a b].find { |s| hit = (pool[s] ||= s) == "b"; [pool].each { _1.store("b", "x") }; hit }
          puts "hit" if a == "b" || b == "b" || c == "b"
        RUBY
      end

      it "withholds it when the fold's own parameter may name the receiver" do
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = Hash.new
          found = [[pool, "a"], [pool, "b"]].find do |h, s|
            hit = (pool[s] ||= s) == "b"
            h["b"] = "x"
            hit
          end
          puts "hit" if found
        RUBY
      end

      it "withholds it when a store through a fresh container may reach the receiver" do
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = Hash.new
          found = %w[a b].find do |s|
            hit = (pool[s] ||= s) == "b"
            box = [pool]
            box[0]["b"] = "x"
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end

      it "withholds it when a store above the site may swap in a filled hash" do
        # The first position replaces `pool[:a]` with `shared`, whose `"b"` is `"x"`. Runtime `nil`.
        expect(flow_rules(<<~RUBY)).to be_empty
          shared = Hash.new
          shared["b"] = "x"
          pool = { a: Hash.new }
          found = %w[a b].find do |s|
            hit = (pool[:a][s] ||= s) == "b"
            pool[:a] = shared
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end

      it "withholds it when the body takes a store method as an object" do
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = Hash.new
          found = %w[a b].find do |s|
            hit = (pool[s] ||= s) == "b"
            pool.method(:[]=).call("b", "x")
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end

      it "withholds it for a key built from a captured local the body mutates" do
        # The typed keys are `"ab"` and `"b"`, but `prefix << "a"` makes the second one `"ab"` too. Runtime `nil`.
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = {}
          prefix = +""
          found = %w[ab b].find do |s|
            hit = (pool[prefix + s] ||= s) == "b"
            prefix << "a"
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end

      it "still withholds the reading when a store the scan cannot attribute may reach the slot" do
        # `other` aliases `pool` inside the body, where the content scan does not follow it, so its store is filed
        # under no captured name and may reach any object. Runtime `nil`, as above.
        expect(flow_rules(<<~RUBY)).to be_empty
          pool = {}
          found = %w[a b].find do |s|
            hit = (pool[s] ||= s) == "b"
            other = pool
            other["b"] = "x"
            hit
          end
          puts "hit" if found == "b"
        RUBY
      end
    end

    describe "the find fold past an undecided position" do
      it "answers the candidates up to a decisive match, without nil" do
        # The first position is undecided and the second always matches, so `find` never returns `nil`.
        expect(dumped_types(<<~RUBY)).to eq(["1 | 2", "0 | 1"])
          x = gets
          dump_type([1, 2].find { |e| e == 2 || x.nil? })
          dump_type([1, 2].find_index { |e| e == 2 || x.nil? })
        RUBY
      end

      it "keeps the nil floor when no position matches decisively (control)" do
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          x = gets
          dump_type([1, 2].find { |e| e == 3 || x.nil? })
        RUBY
      end
    end

    describe "under the generic block-return pass" do
      it "keeps the memo reading for an isolated site (control)" do
        # The generic pass types the rvalue from the parameter's signature type, which covers every iteration's
        # store, so the memo reading still describes the slot there.
        expect(dumped_type(<<~RUBY)).to eq("Array[String]")
          pool = {}
          words = gets.to_s.split(",")
          dump_type(words.map { |w| pool[w] ||= w })
        RUBY
      end

      it "keeps it beside stores into other objects (control)" do
        # A store into `@log`, into an element of `@by_kind`, or into the `@cache[:names]` hash reaches no slot
        # the site's own receiver holds.
        expect(dumped_types(<<~RUBY)).to eq(["Array[String]", "Array[Array]", "Array[String]"])
          class Registry
            def initialize
              @log = []
              @cache = {}
              @by_kind = {}
              @keys = gets.to_s.split(",")
            end

            def logged = dump_type(@keys.map { |k| @log << k; @cache[k] ||= build(k) })
            def grouped = dump_type(@keys.map { |k| (@by_kind[k.size] ||= []) << k })
            def nested = dump_type(@keys.map { |k| (@cache[:names] ||= {})[k] ||= build(k) })
            def build(key) = key.upcase
          end
        RUBY
      end

      it "withholds it when two sites store different values into one slot" do
        # Ruby with input `a,,b` prints `hit`: the empty element stores `:e`, and a later one keeps it and compares
        # it with `:e`. Each site's rvalue alone made both arms provably false.
        expect(flow_rules(<<~RUBY)).to be_empty
          cache = Hash.new
          xs = gets.to_s.split(",")
          hit = xs.any? { |x| x.empty? ? (cache[:k] ||= :e) == :f : (cache[:k] ||= :f) == :e }
          puts "hit" if hit
        RUBY
      end
    end
  end

  # The content half of the pin above. The fixpoint answers the outer locals the body REBINDS; a captured
  # receiver the body only mutates IN PLACE (`h[k] = …`, `h[k] += …`, `seen[x] = true`) is never rebound, so
  # every position still read it at its ENTRY contents: `h = { a: 0 }; [:a, :a].map { |k| h[k] = h[k] + 1 }`
  # folded to `[1, 1]` where Ruby answers `[1, 2]`, and `r.last == 1` fired always-truthy on correct code.
  describe "captured outer locals the body mutates in place under the per-element fold" do
    def flow_rules(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
    end

    it "widens a captured hash the body stores into at every position" do
      # THE REPORTED PROBE. Before the fix this answered `[1, 1]`. The widened value slot carries the one-store
      # `Dynamic[top]` arm, and `+` over `Dynamic[top] | Integer` answers `Dynamic[top]` here exactly as it does
      # on straight-line code.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
        h = { a: 0 }
        dump_type([:a, :a].map { |k| h[k] = h[k] + 1 })
      RUBY
    end

    it "no longer reports the condition the entry contents folded" do
      expect(flow_rules(<<~RUBY)).to be_empty
        h = { a: 0 }
        r = [:a, :a].map { |k| h[k] = h[k] + 1 }
        puts "y" if r.last == 1
      RUBY
    end

    it "widens a captured hash read back after an index compound write" do
      # `[1, 2]` at runtime. The index-write node is no variable write, so the tail was typed from the entry
      # scope and answered `[0, 0]` — the contents before either iteration ran.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top] | Integer, Dynamic[top] | Integer]")
        h = { a: 0 }
        dump_type([:a, :a].map do |k|
          h[k] += 1
          h[k]
        end)
      RUBY
    end

    it "widens a captured array the body stores into" do
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
        a = [0]
        dump_type([0, 0].map { |i| a[i] = a[i] + 1 })
      RUBY
    end

    it "keeps the element class of a captured array read back after a store" do
      # Widening, not a floor: the slot loses its `0` pin and gains the gradual arm, but the Integer the
      # literal proved is still there.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top] | Integer, Dynamic[top] | Integer]")
        a = [0]
        dump_type([0, 0].map do |i|
          a[i] += 1
          a[i]
        end)
      RUBY
    end

    it "leaves a membership test over a hash the body fills undecided" do
      # `[:new, :new, :dup]` at runtime; the entry `{}` made every `key?` provably false.
      expect(dumped_type(<<~RUBY)).to eq("[:dup | :new, :dup | :new, :dup | :new]")
        seen = {}
        dump_type([1, 2, 1].map { |x| seen.key?(x) ? :dup : (seen[x] = true; :new) })
      RUBY
    end

    it "answers a mutated captured local above the per-element threading cap" do
      # The widened binding holds at any point of any iteration, so it answers the tail-only read the cap
      # falls back to, where the #617 floor used to answer `Dynamic[top]` at every position.
      expect(dumped_type(<<~RUBY)).to eq("[#{(['non-negative-int'] * 9).join(', ')}]")
        out = []
        dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
          out << e
          out.size
        end)
      RUBY
    end

    it "widens a captured array whose remover is written before its adder" do
      # `[0, 1]` at runtime. The `pop` closed the literal to `Array[0]` before the `push` could add its
      # gradual arm, so every position read `0?` and `r.last == 1` folded always-falsey.
      expect(dumped_type(<<~RUBY)).to eq("[0 | Dynamic[top] | nil, 0 | Dynamic[top] | nil]")
        stack = [0]
        dump_type([1, 2].map do |x|
          top = stack.pop
          stack.push(x)
          top
        end)
      RUBY
    end

    it "widens the mutated local when the fold is nested inside a threaded body" do
      # The widening evaluates no body, so threading suppression is no reason to skip it.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top] | Integer, Dynamic[top] | Integer]")
        m = Mutex.new
        h = { a: 0 }
        dump_type(m.synchronize do
          v = 1
          [:a, :a].map do |k|
            h[k] += v
            h[k]
          end
        end)
      RUBY
    end

    it "gives a class-changing site the gradual arm its arguments cannot supply" do
      # `map!` joins no argument evidence, so the widening alone kept `Array[Integer]` and `r.last.upcase` drew
      # `undefined method` on a slot that holds `"1"` from the first iteration on.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
        a = [1]
        dump_type([1, 2].map do |e|
          a.map!(&:to_s)
          a.first
        end)
      RUBY
    end

    describe "an empty-witness refinement the body rewrites" do
      # `map!` keeps the `non-empty-array` witness and joins nothing, so the straight-line widening used to decline,
      # and a declined site left `xs` the entry `non-empty-array[String]`: every position read `String` for an element
      # the first iteration already turned into a Symbol, and `r.last.to_proc` drew `undefined method`.
      def rewriting(site, tail)
        <<~RUBY
          xs = gets.to_s.split(",")
          if xs.any?
            r = [1, 2].map do |e|
              xs.#{site}
              xs.first
            end
            #{tail}
          end
        RUBY
      end

      it "reads the rewritten contents through the gradual arm" do
        expect(dumped_type(rewriting("map!(&:to_sym)", "dump_type(r)")))
          .to eq("[Dynamic[top], Dynamic[top]]")
      end

      it "does not report a method the rewritten element defines" do
        expect(undefined_method_rules(rewriting("map!(&:to_sym)", "r.last.to_proc"))).to be_empty
      end

      # The paired control: a site that only reorders cannot change an element's class, so the refinement stands
      # and a call its element does not define still fires.
      it "keeps the element type a reordering site cannot change" do
        expect(dumped_type(rewriting("sort!", "dump_type(r)"))).to eq("[String, String]")
        expect(undefined_method_rules(rewriting("sort!", "r.last.to_proc"))).to eq(["call.undefined-method"])
      end
    end

    it "lays the widened contents under the rebind fixpoint" do
      # `[nil, 0, "s"]` at runtime. The fixpoint for `total` reads `h[:a]`, so it must see `h` as the body leaves
      # it; seeded from the entry `{ a: 0 }` it converged on `0?` at every position.
      expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top] | Integer | nil'] * 3).join(', ')}]")
        h = { a: 0 }
        total = nil
        dump_type([1, 2, 3].map do |i|
          v = total
          total = h[:a]
          h[:a] = "s"
          v
        end)
      RUBY
    end

    it "widens a local the body both rebinds and mutates over its converged type" do
      # The rebind brings a fresh `{ a: 0 }` back each iteration and a store the evaluator does not thread (it
      # sits inside an array literal) rewrites it, so the next iteration reads `{ a: "s" }`. The converged
      # `{ a: 0 }?` alone would pin that.
      widened = "Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]?"
      expect(dumped_type(<<~RUBY)).to eq("[#{([widened] * 3).join(', ')}]")
        h = nil
        dump_type([1, 2, 3].map do |i|
          v = h
          h = { a: 0 }
          [h[:a] = "s"]
          v
        end)
      RUBY
    end

    it "keeps the unmoved-pin floor for a local both mutated and rebound inside an expression" do
      # `["abc", :abc]` at runtime. The nested `s &&= …` is invisible to the fixpoint, which converges on its
      # seed; the seed is the widened `String`, so the #617 floor has to ask the call-site `"ab"` whether a pin
      # is at stake, or `String` is believed and `r.last.to_proc` draws `undefined method`.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
        s = +"ab"
        dump_type([1, 2].map { |i| [s, (s << "c" if s.is_a?(String)), (s &&= s.to_sym).size].first })
      RUBY
    end

    it "keeps an unmutated captured hash read by key exact" do
      expect(dumped_type(<<~RUBY)).to eq("[0, 0]")
        h = { a: 0 }
        dump_type([:a, :a].map { |k| h[k] })
      RUBY
    end

    it "still reports the condition over an unmutated captured hash" do
      # The must-fire sibling: nothing writes `h`, so `r.last == 0` really is always true.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        h = { a: 0 }
        r = [:a, :a].map { |k| h[k] }
        puts "y" if r.last == 0
      RUBY
    end

    it "keeps a captured hash exact when only a sibling is mutated" do
      # Only the mutated receiver moves; `p` is read, never written.
      expect(dumped_type(<<~RUBY)).to eq("[0, 0]")
        q = { a: 0 }
        p = { a: 0 }
        dump_type([:a, :a].map do |k|
          q[k] = 1
          p[k]
        end)
      RUBY
    end
  end

  # The in-place scan above names a mutated local only when the mutation site's RECEIVER reads it. Straight-line
  # code also widens a local whose content changes by two other routes, and every position of a fold read that
  # local at its entry contents: a mutator on an element read (`a[0] << e`, `ElementReadWidening`), and a
  # self-call whose callee content-mutates the matching parameter (`add_to(a, e)`, ADR-57's callee floor).
  describe "captured contents the body mutates through a slot or a callee under the per-element fold" do
    let(:add_to) do
      <<~RUBY
        def add_to(arr, x)
          arr << x
        end
      RUBY
    end

    it "widens a captured tuple whose element the body mutates" do
      # `[1, 2]` at runtime. `a[0]` names no variable, so the scan missed it and both positions read `a[0]` as
      # the entry `[1]`: `[1, 1]`.
      expect(dumped_type(<<~RUBY)).to eq("[non-negative-int, non-negative-int]")
        a = [[1]]
        dump_type([1, 2].map do |e|
          v = a[0].size
          a[0] << e
          v
        end)
      RUBY
    end

    it "no longer reports the condition the entry element folded" do
      expect(flow_rules(<<~RUBY)).to be_empty
        a = [[1]]
        r = [1, 2].map do |e|
          v = a.first.size
          a.first << e
          v
        end
        puts "x" if r.last == 1
      RUBY
    end

    it "keeps the sibling slots of a captured tuple exact" do
      # The widening runs through the path the read names, as the straight-line one does: only `a[0]` moves.
      expect(dumped_type(<<~RUBY)).to eq("[2, 2]")
        a = [[1], [2]]
        dump_type([1, 2].map do |e|
          v = a[1].first
          a[0] << e
          v
        end)
      RUBY
    end

    it "leaves a find over an element the body fills undecided" do
      # `2` at runtime. Both predicates read the entry `[]`, so each was provably false and `find` folded to `nil`.
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        a = [[]]
        dump_type([1, 2].find do |e|
          a[0] << e
          a[0].size == 2
        end)
      RUBY
    end

    it "keeps a captured tuple exact when the body only reads its element" do
      expect(dumped_type(<<~RUBY)).to eq("[1, 1]")
        a = [[1]]
        dump_type([1, 2].map { |e| a[0].size })
      RUBY
    end

    it "floors a captured array a self-call content-mutates" do
      # `[1, 2]` at runtime. The callee's `arr << x` is invisible at the call, so both positions read `[1]`.
      expect(dumped_type(<<~RUBY)).to eq("[non-negative-int, non-negative-int]")
        #{add_to}
        a = [1]
        dump_type([1, 2].map do |e|
          v = a.size
          add_to(a, e)
          v
        end)
      RUBY
    end

    it "no longer reports the condition the entry contents folded under a callee mutation" do
      expect(flow_rules(<<~RUBY)).to be_empty
        #{add_to}
        a = [1]
        r = [1, 2].map do |e|
          v = a.size
          add_to(a, e)
          v
        end
        puts "x" if r.last == 1
      RUBY
    end

    it "leaves a membership test over a hash a callee fills undecided" do
      # `[:new, :new, :dup]` at runtime; the entry `{}` made every `key?` provably false.
      expect(dumped_type(<<~RUBY)).to eq("[:dup | :new, :dup | :new, :dup | :new]")
        def mark(seen, key)
          seen[key] = true
        end
        seen = {}
        dump_type([1, 2, 1].map { |x| seen.key?(x) ? :dup : (mark(seen, x); :new) })
      RUBY
    end

    it "floors a captured array a method in the same class content-mutates" do
      expect(dumped_type(<<~RUBY)).to eq("[non-negative-int, non-negative-int]")
        class Collector
          def run
            a = [1]
            dump_type([1, 2].map do |e|
              v = a.size
              add(a, e)
              v
            end)
          end

          def add(arr, x)
            arr << x
          end
        end
      RUBY
    end

    it "floors a capture passed to a mutator-named method called on self" do
      # `[0, 1]` and `[1, 2]` at runtime. `self.store` and `self.push` carry a mutator's name on a `self` receiver,
      # so the scan took them for in-place sites on `self`, found no variable there, and never asked the callee.
      expect(dumped_types(<<~RUBY)).to eq(["[non-negative-int, non-negative-int]"] * 2)
        class Registry
          def store(h, k)
            h[k] = true
          end

          def push(arr, x)
            arr << x
          end

          def run
            seen = {}
            dump_type([1, 2].map do |e|
              v = seen.size
              self.store(seen, e)
              v
            end)
            buf = [0]
            dump_type([1, 2].map do |e|
              v = buf.size
              self.push(buf, e)
              v
            end)
          end
        end
      RUBY
    end

    it "floors a string refinement a callee can empty, under the fold and after a straight-line call" do
      # `[false, true]` and `true` at runtime. The floor kept `non-empty-string`, so `empty?` folded to `false`.
      expect(dumped_types(<<~RUBY)).to eq(["[bool, bool]", "bool"])
        def reset(s)
          s.replace("")
        end
        s = RUBY_VERSION.upcase
        dump_type([1, 2].map do |e|
          v = s.empty?
          reset(s)
          v
        end)
        t = RUBY_VERSION.upcase
        reset(t)
        dump_type(t.empty?)
      RUBY
    end

    it "floors a string refinement an escaping block mutates, directly or through a callee" do
      # The escaping-block floor shares the straight-line callee floor's carrier test, which read only a plain
      # `String`: both locals left `Thread.new` still `decimal-int-string`, although `"5x"` is not one.
      expect(dumped_types(<<~RUBY)).to eq(%w[String String])
        def app(x)
          x << "y"
        end
        s = rand(10).to_s
        Thread.new { s << "x" }
        dump_type(s)
        u = rand(10).to_s
        Thread.new { app(u) }
        dump_type(u)
      RUBY
    end

    it "keeps a captured array exact when the callee only reads it" do
      expect(dumped_type(<<~RUBY)).to eq("[1, 1]")
        def peek(arr, x)
          arr.size + x
        end
        a = [1]
        dump_type([1, 2].map do |e|
          v = a.size
          peek(a, e)
          v
        end)
      RUBY
    end

    it "keeps a captured array exact when the callee mutates a different parameter" do
      expect(dumped_type(<<~RUBY)).to eq("[1, 1]")
        def copy_size(src, dst)
          dst << src.size
        end
        a = [1]
        b = []
        dump_type([1, 2].map do |e|
          v = a.size
          copy_size(a, b)
          v
        end)
      RUBY
    end

    it "widens a callee-mutated capture a rebind reads across an each loop" do
      # `"s"` at runtime. The ADR-56 write-back's fixpoint pass read `a` at its entry `[:x]` every iteration, so
      # `last` left the loop as `:x?`.
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]?")
        #{add_to}
        a = [:x]
        last = nil
        [1, 2].each do |e|
          last = a.last
          add_to(a, "s")
        end
        dump_type(last)
      RUBY
    end

    it "widens both routes under the HashShape per-pair fold" do
      # `{ x: 1, y: 2 }` twice at runtime; each folded `{ x: 1, y: 1 }`.
      expect(dumped_types(<<~RUBY)).to eq(["{ x: non-negative-int, y: non-negative-int }"] * 2)
        #{add_to}
        a = [[1]]
        dump_type({ x: 1, y: 2 }.transform_values do |e|
          v = a[0].size
          a[0] << e
          v
        end)
        b = [1]
        dump_type({ x: 1, y: 2 }.transform_values do |e|
          v = b.size
          add_to(b, e)
          v
        end)
      RUBY
    end

    it "widens both routes under the generic block-return pass" do
      # A receiver with no per-element fold. Each answered `Array[1]` where the runtime holds `[1, 2]`.
      expect(dumped_types(<<~RUBY)).to eq(["Array[non-negative-int]"] * 2)
        #{add_to}
        xs = [1, 2].to_a.shuffle
        a = [[1]]
        dump_type(xs.map do |e|
          v = a[0].size
          a[0] << e
          v
        end)
        b = [1]
        dump_type(xs.map do |e|
          v = b.size
          add_to(b, e)
          v
        end)
      RUBY
    end
  end

  describe "the per-element Tuple fold's arity cap" do
    it "threads every position at the cap" do
      expect(dumped_type(<<~RUBY)).to eq("[1, 2, 3, 4, 5, 6, 7, 8]")
        dump_type([1, 2, 3, 4, 5, 6, 7, 8].map do |e|
          v = e
          v
        end)
      RUBY
    end

    it "falls back to tail-only typing one element past the cap" do
      # The documented cliff: each threaded position costs a FULL body evaluation, so past the cap the walk
      # still folds per position but types each one tail-only. A ninth element therefore drops the values.
      type = dumped_type(<<~RUBY)
        dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
          v = e
          v
        end)
      RUBY
      expect(type).to eq("[#{(['Dynamic[top]'] * 9).join(', ')}]")
    end

    it "leaves the fold itself untouched past the cap" do
      # Only the threading is capped: a single-statement body never needed it, so the fold still answers the
      # exact per-position values at any arity.
      expect(dumped_type("dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map { |e| e })"))
        .to eq("[1, 2, 3, 4, 5, 6, 7, 8, 9]")
    end
  end

  # The same first-iteration pin on an instance variable. An ivar is not captured — the block shares the
  # method's `self` — but it persists across iterations exactly as a captured local does, and every position
  # read it at its entry binding: `@t = 0; [1, 2].map { @t += 1 }` folded to `[1, 1]` (runtime `[1, 2]`). The
  # fold runs the captured-local fixpoint over the ivars the body rebinds too, under the same #617 residue
  # rules, and every ivar the body leaves alone keeps its exact binding.
  describe "instance variables the body rebinds under the per-element fold" do
    # `source` as the body of an instance method, where the ivar under test is bound.
    def in_method(source) = "class Counter\ndef run\n#{source}\nend\nend\n"

    def flow_rules(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{in_method(source)}))
      result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
    end

    it "widens a rebound ivar counter at every position" do
      # The reported probe: the compound write is the whole body, so each position's value is the stored `@t`.
      expect(dumped_type(in_method(<<~RUBY))).to eq("[Integer, Integer]")
        @t = 0
        dump_type([1, 2].map { |k| @t += 1 })
      RUBY
    end

    it "widens an ivar tail read back after the rebind" do
      # Runtime `[1, 3]`; the pin answered `[1, 2]`.
      expect(dumped_type(in_method(<<~RUBY))).to eq("[Integer, Integer]")
        @t = 0
        dump_type([1, 2].map do |e|
          @t += e
          @t
        end)
      RUBY
    end

    it "no longer reports the condition the first-iteration pin used to fold" do
      expect(flow_rules(<<~RUBY)).to be_empty
        @t = 0
        r = [1, 2].map { @t += 1 }
        puts "x" if r.last == 1
      RUBY
    end

    it "still reports the condition over an ivar the body does not rebind" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        @t = 0
        r = [1, 2].map { |e| @t }
        puts "x" if r.last == 0
      RUBY
    end

    it "keeps a position whose tail reads an ivar the body does not rebind" do
      expect(dumped_type(in_method(<<~RUBY))).to eq("[5, 5]")
        @t = 0
        @u = 5
        dump_type([1, 2].map do |e|
          @t += e
          @u
        end)
      RUBY
    end

    it "keeps an ivar the body writes before reading it back exact" do
      # Each position reads the value its own iteration stored, whatever the fixpoint binds on entry.
      expect(dumped_type(in_method(<<~RUBY))).to eq("[1, 2]")
        @last = 0
        dump_type([1, 2].map do |e|
          @last = e
          @last
        end)
      RUBY
    end

    it "widens an `||=` memo the first iteration fills" do
      # Runtime `[1, 1]`: the second iteration finds `@q` already set. The pin answered `[1, 2]`.
      expect(dumped_type(in_method(<<~RUBY))).to eq("[1 | 2, 1 | 2]")
        @q = nil
        dump_type([1, 2].map { |e| @q ||= e })
      RUBY
    end

    it "keeps a local that shares the rebound ivar's bare name" do
      # Locals and ivars share one name map, told apart by the `@` Ruby spells every ivar with.
      expect(dumped_type(in_method(<<~RUBY))).to eq("[5, 5]")
        t = 5
        @t = 0
        dump_type([1, 2].map do |e|
          @t += e
          t
        end)
      RUBY
    end

    it "widens a local and an ivar the same body rebinds" do
      expect(dumped_type(in_method(<<~RUBY))).to eq("[[Integer, Integer], [Integer, Integer]]")
        total = 0
        @t = 0
        dump_type([1, 2].map do |e|
          total += e
          @t += 1
          [total, @t]
        end)
      RUBY
    end

    it "keeps a predicate fold that ignores the rebound ivar" do
      expect(dumped_type(in_method(<<~RUBY))).to eq("[2]")
        @seen = 0
        dump_type([1, 2].select do |e|
          @seen += 1
          e > 1
        end)
      RUBY
    end

    it "answers find's element-or-nil floor over a rebound-ivar predicate" do
      # Issue #617 residue (1) on an ivar: runtime `2`, and the pin answered `nil`.
      expect(dumped_type(in_method(<<~RUBY))).to eq("1 | 2 | nil")
        @seen = 0
        dump_type([1, 2].find do |e|
          @seen += 1
          @seen == 2
        end)
      RUBY
    end

    it "floors the unmoved pin of a rebind nested inside an expression" do
      # `(@seen += 1) == 2` is no statement, so the fixpoint's body evaluation never threads it and converges
      # on the `Constant[0]` seed; the residue rule floors that seed rather than believing it.
      expect(dumped_type(in_method(<<~RUBY))).to eq("1 | 2 | nil")
        @seen = 0
        dump_type([1, 2].find { |e| (@seen += 1) == 2 })
      RUBY
    end

    it "keeps the class-seeded binding of an ivar another method initializes" do
      # `@n` enters `run` on its class-wide binding, `0 | Integer` — the union of every write in the class,
      # this body's included — so it is no first-iteration pin and the fold leaves it alone.
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        class Counter
          def initialize
            @n = 0
          end

          def run
            dump_type([1, 2].map { @n += 1 })
          end
        end
      RUBY
    end

    it "keeps the class-wide binding when a nested block rebinds the ivar" do
      # The nested `each` write is never threaded back into the fold's exit scope, so the fixpoint converges
      # on `:fast | :slow` — a literal union the unmoved-pin floor would take. It needs no floor: that union
      # is every value the class ever stores.
      expect(dumped_type(<<~RUBY)).to eq("[:fast | :slow, :fast | :slow]")
        class Mode
          def initialize
            @mode = :fast
          end

          def run
            dump_type([1, 2].map do |x|
              [x].each { @mode = :slow }
              @mode
            end)
          end
        end
      RUBY
    end

    it "keeps a class-seeded `||=` memo exact" do
      # `@mode` only ever holds `:fast`, so the memo answers `:fast` at every position.
      expect(dumped_type(<<~RUBY)).to eq("[:fast, :fast]")
        class Mode
          def initialize
            @mode = :fast
          end

          def run
            dump_type([1, 2].map { @mode ||= :fast })
          end
        end
      RUBY
    end

    it "floors an unthreaded ivar rebind behind a narrowing guard" do
      # Runtime `2`; the entry-scope pin answered `nil`.
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        class Counter
          def run(flag)
            @s = flag ? 0 : nil
            dump_type([1, 2].find { |e| next false unless @s; (@s += 1) == 2 })
          end
        end
      RUBY
    end

    it "keeps the optimistic nil-freeness mark on a rebound ivar" do
      # Runtime `[false, false]`: `xs` is empty. Dropping the mark folded `@v.nil?` to `false`.
      expect(dumped_type(in_method(<<~RUBY))).to eq("[bool, bool]")
        xs = Array.new(rand(0)) { |i| i }
        @v = xs.first
        dump_type([1, 2].map do |e|
          out = @v.nil? ? false : true
          @v = xs.first
          out
        end)
      RUBY
    end

    it "reports nothing on the optimistic ivar's fold" do
      expect(flow_rules(<<~RUBY)).to be_empty
        xs = Array.new(rand(0)) { |i| i }
        @v = xs.first
        r = [1, 2].map do |e|
          out = @v.nil? ? false : true
          @v = xs.first
          out
        end
        puts "missing" unless r.first
      RUBY
    end

    it "still reads the fixpoint above the per-element threading cap" do
      # A rebound ivar is answered at any arity, so the arity-cap floor must not take it.
      expect(dumped_type(in_method(<<~RUBY))).to eq("[#{(['Integer'] * 9).join(', ')}]")
        @t = 0
        dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
          @t += e
          @t
        end)
      RUBY
    end

    it "floors the rebound ivar when the fold is nested inside a threaded body" do
      expect(dumped_type(in_method(<<~RUBY))).to eq("[Dynamic[top], Dynamic[top]]")
        m = Mutex.new
        @t = 0
        dump_type(m.synchronize do
          v = 1
          [1, 2].map do
            @t += v
            @t
          end
        end)
      RUBY
    end
  end

  describe "a captured local the body mutates in place and rebinds as a statement" do
    # The unmoved-pin floor asks the call-site binding, not the in-place widened seed, even when the body rebinds
    # the name as a statement: converging on the widened seed next to a statement rebind does not show that the
    # rebind was all there was. These fixtures are the two routes that would otherwise report on correct code.
    it "keeps the floor for a statement rebind that lands inside the widened seed" do
      # `["abcc", "abcc"]` at runtime; `String` is right here, but nothing the fixpoint sees tells this body from
      # the two below.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
        s = +"ab"
        dump_type([1, 2].map { |e| s << "c"; s = s.strip; s })
      RUBY
    end

    it "does not report a rebind the capped fixpoint never runs" do
      # Runtime `r.last` is `[5, "c"]`: `n` reaches the cap before the guarded `s = [e]` runs in any pass, so `s`
      # converges on its widened `String` seed.
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        s = +"ab"
        n = 0
        r = [1, 2, 3, 4, 5, 6].map { |e| t = s; s << "c"; s = s.dup; n += 1; s = [e] if n > 3; t }
        r.last.push(0)
      RUBY
    end

    it "does not report a rebind a lambda defined outside the body makes" do
      # Runtime `[false, false, true]`: `close.call` rebinds `cur` where no write node in the body shows it.
      expect(flow_rules(<<~RUBY)).to be_empty
        cur = nil
        close = -> { cur = nil }
        cur = +""
        flags = %w[a b. c].map do |w|
          was_nil = cur.nil?
          cur ||= +""
          cur << w
          cur = cur.strip
          close.call if w.end_with?(".")
          was_nil
        end
        puts "restarted" if flags.last
      RUBY
    end
  end

  describe "a nested block's parameter shadowing a captured name" do
    it "does not treat a write to the shadowing parameter as a rebind of the outer local" do
      # `[1, 1]` at runtime: `a = k` rebinds the inner block's `|a|`. Counted as a rebind of the outer `a`, the
      # fixpoint converged on the pinned `[1]` seed and the unmoved-pin floor took it.
      expect(dumped_type(<<~RUBY)).to eq("[1, 1]")
        a = [1]
        dump_type([1, 2].map { |k| [[]].each { |a| a = k }; a.first })
      RUBY
    end

    it "does not treat a mutation of the shadowing parameter as a mutation of the outer local" do
      expect(dumped_type(<<~RUBY)).to eq("[1, 1]")
        a = [1]
        dump_type([1, 2].map { |k| [[]].each { |a| a << k }; a.first })
      RUBY
    end

    it "does not treat a nested def's local as a rebind of the outer local" do
      # `[0, 0]` at runtime: the `def`'s `z` is the method's own local.
      expect(dumped_type(<<~RUBY)).to eq("[0, 0]")
        z = 0
        dump_type([1, 2].map { |k| def helper; z = 5; end; z })
      RUBY
    end

    it "still floors a rebind in a singleton-class target, which runs in the enclosing scope" do
      # `[nil, #<Object>]` at runtime; `r.last.tag` must not read a stale `nil`.
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        def sclass_real
          target = nil
          objs = [Object.new, Object.new]
          r = [1, 2].map { |k| prev = target; class << (target = objs[k - 1]); def tag = :t; end; prev }
          r.last.tag
        end
      RUBY
    end

    it "still widens the outer local a nested block without the shadow rebinds" do
      expect(dumped_type(<<~RUBY)).not_to eq("[1, 1]")
        a = [1]
        dump_type([1, 2].map { |k| [[]].each { |b| a = [k] }; a.first })
      RUBY
    end
  end

  describe "declines — the answer must not move" do
    it "keeps a single-statement block body on the tail-only path" do
      expect(dumped_type("dump_type(Mutex.new.synchronize { 42 })")).to eq("42")
    end

    it "keeps an identity block over a Tuple receiver unchanged" do
      expect(dumped_type("dump_type([1, 2].map { |e| e })")).to eq("[1, 2]")
    end

    it "leaves a tail reading a def parameter honest" do
      # No binding exists for `x` beyond the parameter, so `Dynamic[top]` is the correct answer, not a gap
      # the threading should close.
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
        def run(x)
          m = Mutex.new
          dump_type(m.synchronize do
            k = 1
            x
          end)
        end
      RUBY
    end

    it "leaves a tail reading an outer local unchanged" do
      expect(dumped_type(<<~RUBY)).to eq("7")
        m = Mutex.new
        o = 7
        dump_type(m.synchronize do
          k = 1
          o
        end)
      RUBY
    end

    it "leaves a block parameter shadowing a body-written name to the parameter" do
      expect(dumped_type(<<~RUBY)).to eq("[9]")
        m = Mutex.new
        dump_type(m.synchronize do
          s = 1
          [9].map { |s| s }
        end)
      RUBY
    end

    it "leaves the non-block sequencing path alone" do
      # `x = begin a = 42; a end` never went through the block-return pass and already answered `42`; the
      # shared `statements_type_for` must stay untouched.
      expect(dumped_type(<<~RUBY)).to eq("42")
        x = begin
          a = 42
          a
        end
        dump_type(x)
      RUBY
    end
  end

  # PR #584 review NIT 6 — `dumped_type` reads only the first dump, so this pins the property that makes
  # that safe for every fixture in the file: one `dump_type` call in, exactly one dump diagnostic out. A
  # fixture that grew a second call would be losing an answer silently rather than failing here.
  it "reports exactly one dump per fixture" do
    types = dumped_types(<<~RUBY)
      m = Mutex.new
      dump_type(m.synchronize do
        v = 42
        v
      end)
    RUBY
    expect(types).to eq(["42"])
  end

  describe "corpus shapes the fix was measured against" do
    it "types concurrent-ruby's read_write_lock predicate block" do
      # `read_write_lock.rb:179` — a `wait_until`-shaped block whose tail predicate reads the local its
      # first statement binds.
      expect(dumped_type(<<~RUBY)).to eq("true")
        class Lock
          def initialize
            @counter = 0
            @write_lock = Mutex.new
          end

          def running?(c) = c > 0

          def acquire
            dump_type(@write_lock.synchronize do
              c = @counter
              !running?(c) && !running?(c)
            end)
          end
        end
      RUBY
    end

    it "types textbringer's lsp request-id block" do
      # `lsp/client.rb:328` — the id is allocated inside the block and returned as the tail.
      # The answer is `Integer`, not `1`: #1175 seeds `@request_id += 1` into the class-ivar table,
      # so the entry binding is `0 | Integer` rather than the pinned `Constant[0]` that folded the
      # counter to its first-call value.
      expect(dumped_type(<<~RUBY)).to eq("Integer")
        class Client
          def initialize
            @mutex = Mutex.new
            @request_id = 0
            @pending = {}
          end

          def write_message(message) = message

          def send_request(method, params, &callback)
            dump_type(@mutex.synchronize do
              @request_id += 1
              id = @request_id
              message = { jsonrpc: "2.0", id: id, method: method, params: params }
              @pending[id] = callback if callback
              write_message(message)
              id
            end)
          end
        end
      RUBY
    end
  end

  # Issue #617 — the four block-return residues #587 left behind. Each pair is a residue plus the arm that
  # must keep folding, because every decline here is bought with precision somewhere adjacent.
  describe "issue #617 block-return residues" do
    describe "(1) find / detect / index / find_index over a rebound-capture predicate" do
      it "answers an element-or-nil where the entry-scope predicate short-circuited to nil" do
        # Runtime answer is `2`. The per-position predicates do not fold, so the walk floors instead of
        # letting `BlockFolding` read the first iteration's `Constant[false]` and return `nil`.
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          seen = 0
          dump_type([1, 2].find do |e|
            seen += 1
            seen == 2
          end)
        RUBY
      end

      it "answers Integer? for the same shape under index" do
        # Runtime answer is `1`.
        expect(dumped_type(<<~RUBY)).to eq("Integer?")
          seen = 0
          dump_type([1, 2].index do |e|
            seen += 1
            seen == 2
          end)
        RUBY
      end

      it "answers the one-liner form too" do
        # `(seen += 1) == 2` rebinds inside an expression, which the body evaluator does not thread, so the
        # fixpoint came back on its seed and every position re-read `Constant[0]`.
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          seen = 0
          dump_type([1, 2].find { |e| (seen += 1) == 2 })
        RUBY
      end

      it "still floors an unthreaded rebind behind a narrowing guard" do
        # `next false unless seen` narrows `seen` on the way out of the body, so the exit binding differs
        # from the entry one although `(seen += 1) == 2` is never threaded. The floor must still take the
        # `0 | nil` seed; believing it answered `nil` where Ruby answers `2`.
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          def run(flag)
            seen = flag ? 0 : nil
            dump_type([1, 2].find { |e| next false unless seen; (seen += 1) == 2 })
          end
        RUBY
      end

      it "no longer reports the always-falsey condition the narrowed pin folded" do
        expect(flow_rules(<<~RUBY)).to be_empty
          def run(flag)
            seen = flag ? 0 : nil
            r = [1, 2].find { |e| next false unless seen; (seen += 1) == 2 }
            puts "found" if r
          end
        RUBY
      end

      it "still floors an unthreaded rebind that an `||=` prefix threads" do
        # The threaded `seen ||= 0` moves the exit binding to `0`; the counter itself never moves.
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          def run(flag)
            seen = flag ? 0 : nil
            dump_type([1, 2].find { |e| seen ||= 0; (seen += 1) == 2 })
          end
        RUBY
      end

      it "still floors a union seed that an unthreaded write of another class escapes" do
        # `when (seen = nil)` stores nil in a `when` condition, which the body evaluator does not thread, so the
        # fixpoint converges on the `0 | Integer` seed. That seed holds every Integer, but not the nil: keeping
        # it folded `seen.nil?` to `false` at both positions, and `find` to `nil` where Ruby answers `1`.
        expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
          def run(flag)
            seen = flag ? 0 : rand(10)
            dump_type([1, 2].find { |e| case e when (seen = nil) then 0 end; seen.nil? })
          end
        RUBY
      end

      it "reads a write of another class stored inside an argument" do
        # Issue #1223 threads `log(seen = nil)`, so the body reads `nil` and `find` answers the first element, as
        # Ruby does. The fold's scan still floors `seen` across passes; only this pass's own write is seen.
        expect(dumped_type(<<~RUBY)).to eq("1")
          def log(x) = x

          def run(flag)
            seen = flag ? 0 : rand(10)
            dump_type([1, 2].find { |e| log(seen = nil); seen.nil? })
          end
        RUBY
      end

      it "still folds find to the matching element when the predicate decides" do
        expect(dumped_type("dump_type([1, 2].find { |e| e == 2 })")).to eq("2")
      end

      it "still folds find to nil when no position matches" do
        expect(dumped_type("dump_type([1, 2].find { |e| e == 5 })")).to eq("nil")
      end

      it "still folds index to the matching position" do
        expect(dumped_type("dump_type([1, 2].index { |e| e == 2 })")).to eq("1")
      end
    end

    # The fixpoint stops after `BodyFixpoint::CAP` passes, so a rebind a counter guards past the third iteration
    # runs in none of them, and the widen on the capped pass erases a `Constant`'s value but leaves a `Tuple` /
    # `HashShape` as it is. The
    # name comes back on its seed, and only the unmoved-pin floor stands between that seed and every position of
    # the fold, so a shape carrier has to count as pinned there.
    describe "(1), a Tuple or HashShape seed the capped fixpoint never moves" do
      it "floors a Tuple seed whose guarded rebind no fixpoint pass runs" do
        # Runtime `[[], [], [], [], [4, 4], [5, 5]]`; every position answered the entry `[]`.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top]'] * 6).join(', ')}]")
          count = 0
          row = []
          dump_type([1, 2, 3, 4, 5, 6].map { |v| prev = row; count += 1; row = [v, v] if count > 3; prev })
        RUBY
      end

      it "no longer reports the comparison the pinned size folded" do
        # Runtime `[0, 0, 0, 0, 2, 2]`; `sizes.last == 2` folded always-falsey off the entry `[]`.
        expect(flow_rules(<<~RUBY)).to be_empty
          count = 0
          row = []
          sizes = [1, 2, 3, 4, 5, 6].map { |v| prev = row; count += 1; row = [v, v] if count > 3; prev.size }
          puts "full" if sizes.last == 2
        RUBY
      end

      it "floors a HashShape seed the same way" do
        # Runtime `{ a: 0, b: 1 }` at the sixth position; the entry `{ a: 0 }` answered all six.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top]'] * 6).join(', ')}]")
          n = 0
          h = { a: 0 }
          dump_type([1, 2, 3, 4, 5, 6].map { |i| x = h; n += 1; h = { a: 0, b: 1 } if n == 5; x })
        RUBY
      end

      it "floors the seed under the generic block-return pass too" do
        # A plain Array receiver has no per-element fold; the dispatcher's block-return pass lays the same binding
        # and answered `Array[[0]]`.
        expect(dumped_type(<<~RUBY)).to eq("Array[Dynamic[top]]")
          n = 0
          g = [0]
          dump_type(ARGV.map { |a| x = g; n += 1; g = [0, 1] if n == 5; x })
        RUBY
      end

      it "still widens a Constant seed the same fixpoint never moves" do
        # The capped pass widens `0` to `Integer`, which moves it off its seed. That covers a later rebind of the same
        # class only; a class-changing one (`m = nil if n == 5`) still escapes, issue #1260.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Integer'] * 6).join(', ')}]")
          n = 0
          m = 0
          dump_type([1, 2, 3, 4, 5, 6].map { |i| x = m; n += 1; m = 7 if n == 5; x })
        RUBY
      end

      it "keeps a nominal seed a rebind brings back unchanged" do
        # `names.select { … }` rebinds `names` to the `Array[String]` it started from: unmoved, but carrying no
        # pin, so it is believed.
        expect(dumped_type(<<~RUBY)).to eq("[Array[String], Array[String]]")
          names = ARGV.map(&:upcase)
          dump_type([1, 2].map { |i| prev = names; names = names.select { |s| s.size > i }; prev })
        RUBY
      end

      it "floors a shape seed a visible write restores to its entry value" do
        # The cost side, which `n = 0; … n = 0` already pays: a threaded `buf = []` converges on the `[]` seed
        # exactly as a guarded rebind does, so the runtime `[[], []]` is given up.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          buf = []
          dump_type([1, 2].map { |i| out = buf; buf = []; out })
        RUBY
      end

      it "floors a shape seed a rebind of the same type leaves unmoved" do
        # The cost is wider for a shape than for a Constant: the unmoved test is type equality, so a rebind to a
        # different value of the same `[Integer, Integer]` is floored too. It answered `[Integer, Integer]`.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          n = ARGV.size
          qr = n.divmod(3)
          dump_type([1, 2].map { |i| out = qr; qr = n.divmod(i + 2); out })
        RUBY
      end
    end

    # The unmoved-pin floor is also the backstop behind `UnthreadedRebinds`, which floors every rebind it can show
    # the pass's exit scope misses. That scan is a whitelist written against `StatementEvaluator`, so a position
    # the two ever disagree on reaches the fixpoint unflagged; stubbing the scan empty stands in for that drift.
    #
    # Each rebind sits in a `when` condition, a position the evaluator does not thread, so the fixpoint cannot see
    # it. If the evaluator ever threads that position, move these rebinds to one it still does not.
    describe "(1), the unmoved-pin floor over a shape seed the scan misses" do
      before do
        allow(Rigor::Inference::UnthreadedRebinds).to receive(:names).and_return(Set.new)
      end

      it "floors a Tuple seed an unthreaded rebind leaves unmoved" do
        # Runtime `[[0], [0, 1]]`.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          g = [0]
          dump_type([1, 2].map { |i| x = g; case i when (g += [1]) then 0 end; x })
        RUBY
      end

      it "no longer reports the size check the pinned arity folded" do
        expect(flow_rules(<<~RUBY)).to be_empty
          g = [0]
          r = [1, 2].map { |i| x = g; case i when (g += [1]) then 0 end; x }
          puts "one" if r.last.size == 1
        RUBY
      end

      it "floors a HashShape seed the same way" do
        # Runtime `[{ a: 0 }, { a: 0, b: 1 }]`.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          h = { a: 0 }
          dump_type([1, 2].map { |i| x = h; case i when (h = h.merge(b: 1)) then 0 end; x })
        RUBY
      end

      it "floors a Tuple seed that is one member of a union" do
        # Runtime `[[0], [0, 1]]` when `flag` holds.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          def run(flag)
            g = flag ? [0] : nil
            dump_type([1, 2].map { |i| x = g; case i when (g = [0, 1]) then 0 end; x })
          end
        RUBY
      end

      it "keeps the exact fold of a Tuple capture the body does not rebind" do
        expect(dumped_type(<<~RUBY)).to eq("[[0], [0]]")
          c = [0]
          seen = 0
          dump_type([1, 2].map { |i| seen += 1; c })
        RUBY
      end

      it "keeps the converged fold of a Tuple seed a threaded rebind moves" do
        expect(dumped_type(<<~RUBY)).to eq("[[0] | [1], [0] | [1]]")
          g = [0]
          dump_type([1, 2].map { |i| x = g; g = [1]; x })
        RUBY
      end
    end

    # The filter family's fall-through was not merely wider either: `BlockFolding` folds `select` / `reject` on
    # a `Constant` block, and the entry-scope pin hands it one, so an undecided walk fell through to a
    # provably-empty answer. The floor is an Array of the receiver's own elements.
    describe "(1), filter family: select / filter / reject over a rebound-capture predicate" do
      it "answers an Array of the elements where the entry-scope predicate emptied a select" do
        # Runtime answer is `[2]`; the fall-through read `seen == 2` as `1 == 2` and answered `[]`.
        expect(dumped_type(<<~RUBY)).to eq("Array[1 | 2]")
          seen = 0
          dump_type([1, 2].select do |e|
            seen += 1
            seen == 2
          end)
        RUBY
      end

      it "answers the same floor for filter" do
        expect(dumped_type(<<~RUBY)).to eq("Array[1 | 2]")
          seen = 0
          dump_type([1, 2].filter do |e|
            seen += 1
            seen == 2
          end)
        RUBY
      end

      it "answers the same floor for a reject the pin emptied" do
        # Runtime answer is `[2]`; the pin read `seen == 1` as always true, so every element was rejected.
        expect(dumped_type(<<~RUBY)).to eq("Array[1 | 2]")
          seen = 0
          dump_type([1, 2].reject do |e|
            seen += 1
            seen == 1
          end)
        RUBY
      end

      it "no longer reports the emptiness the pinned predicate folded" do
        expect(flow_rules(<<~RUBY)).to be_empty
          seen = 0
          r = [1, 2].select do |e|
            seen += 1
            seen == 2
          end
          puts "none" if r.size == 0
        RUBY
      end

      it "no longer reports a nil receiver read out of the emptied select" do
        expect(undefined_method_rules(<<~RUBY)).to be_empty
          seen = 0
          r = [1, 2].select do |e|
            seen += 1
            seen == 2
          end
          r.first + 1
        RUBY
      end

      it "widens a range receiver's elements, which carry no pin the program wrote" do
        # The RBS answer the floor replaces had no pin; keeping the enumerated `1 | 2 | 3 | 4` would leave an
        # Array a later `<<` cannot widen.
        expect(dumped_type(<<~RUBY)).to eq("Array[Integer]")
          i = rand(2)
          dump_type((1..4).filter { |e| e.even? == (i > 0) })
        RUBY
      end

      it "does not fold a comparison against a value appended to the range's floor" do
        expect(flow_rules(<<~RUBY)).to be_empty
          i = rand(2)
          q = (1..4).filter { |e| e.even? == (i > 0) }
          q << 9
          puts "nine" if q.last == 9
        RUBY
      end

      it "still folds select to the kept elements when the predicate decides" do
        expect(dumped_type("dump_type([1, 2].select { |e| e > 1 })")).to eq("[2]")
      end
    end

    describe "(2) the content-mutation family above the per-element threading cap" do
      it "floors a position whose tail reads a parameter the body mutated in place" do
        # `[[]] * 9` is nine references to ONE array, which the nine `<<` leave holding nine `1`s; the walk
        # answered nine provably-empty `[]`. The cap withholds the per-position body evaluation, so the honest
        # answer above it is "unknown", not the pre-state.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top]'] * 9).join(', ')}]")
          dump_type(([[]] * 9).map do |a|
            a << 1
            a
          end)
        RUBY
      end

      it "keeps threading the same shape at the cap" do
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Array[Dynamic[top] | Integer]'] * 8).join(', ')}]")
          dump_type(([[]] * 8).map do |a|
            a << 1
            a
          end)
        RUBY
      end

      it "floors a position whose tail reads a parameter the body stored into through an index write" do
        # The same floor for the index-write forms, which the prefix scan used to miss. `[{ a: 0 }] * 9` is
        # nine references to one hash, which ends as `{ a: 9 }`; the walk answered nine stale `{ a: 0 }`.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top]'] * 9).join(', ')}]")
          dump_type(([{ a: 0 }] * 9).map do |h|
            h[:a] += 1
            h
          end)
        RUBY
      end

      it "threads the index-write shape at the cap" do
        widened = "Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]"
        expect(dumped_type(<<~RUBY)).to eq("[#{([widened] * 8).join(', ')}]")
          dump_type(([{ a: 0 }] * 8).map do |h|
            h[:a] += 1
            h
          end)
        RUBY
      end

      it "still reads the captured-local fixpoint above the cap" do
        # The floor consults the fixpoint's names: `total` IS answered at any arity, so it must not be
        # floored along with the mutated parameter.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Integer'] * 9).join(', ')}]")
          total = 0
          dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
            total += e
            total
          end)
        RUBY
      end

      it "answers a captured empty-witness refinement a class-changing site rewrites" do
        # `map!` keeps a `non-empty-array` witness and rewrites every element, so `xs` moves and is answered
        # rather than floored.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top]'] * 9).join(', ')}]")
          xs = ENV.keys
          unless xs.empty?
            dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
              xs.map!(&:to_sym)
              xs.first
            end)
          end
        RUBY
      end

      it "answers a captured literal Hash the body shifts" do
        # `Hash#shift` was missing from the Hash mutator table, so the widening declined and this was floored; when
        # it was counted as answered instead, `h` stayed the entry literal, typed nine `9`s (runtime `8, 7, …, 0`)
        # and fired always-truthy on `r.last == 9`. It now widens as `delete` does.
        source = <<~RUBY
          h = { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9 }
          r = [1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
            h.shift
            h.size
          end
        RUBY
        expect(dumped_type("#{source}dump_type(r)")).to eq("[#{(['non-negative-int'] * 9).join(', ')}]")
        expect(flow_rules("#{source}puts 'nine' if r.last == 9")).to be_empty
      end

      it "floors a captured precise nominal the body appends to" do
        # `Array[String]` is a claim the widening may not grow, so it declines and the name stays unanswered.
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top]'] * 9).join(', ')}]")
          ks = ENV.keys
          dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
            ks << e
            ks.last
          end)
        RUBY
      end

      it "reads a class-changing site through its gradual arm" do
        expect(dumped_type(<<~RUBY)).to eq("[#{(['Dynamic[top]'] * 9).join(', ')}]")
          a = [1]
          dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
            a.map!(&:to_s)
            a.first
          end)
        RUBY
      end

      it "reads a merging site through its gradual arm" do
        expect(dumped_type(<<~RUBY)).to eq("[#{(['1 | Dynamic[top]'] * 9).join(', ')}]")
          m = { k: 1 }
          dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
            m.merge!(k: "s")
            m[:k]
          end)
        RUBY
      end

      it "leaves a tail that ignores its prefix precise above the cap" do
        expect(dumped_type(<<~RUBY)).to eq("[#{(['5'] * 9).join(', ')}]")
          dump_type([1, 2, 3, 4, 5, 6, 7, 8, 9].map do |e|
            q = e
            5
          end)
        RUBY
      end
    end

    # The same pre-state at ANY arity. A fold nested inside a body another pass is evaluating whole runs under
    # the suppression that keeps the threading from re-entering, so every position is typed tail-only exactly as
    # it is above the cap — and the per-pair HashShape fold, which has no cap, reaches a pair the dependency scan
    # can flag only this way. The outer body threads only when its own tail reads a name its prefix binds: most
    # fixtures route the outer `w` into the inner block, one assigns the fold's result and reads it back
    # (`y = fold; y`), and "threads the same body when the outer tail does not read its own prefix" does
    # neither, to show the floor follows the suppression rather than the lexical nesting.
    describe "(2), nested: the same family under block-body threading suppression" do
      it "floors a Tuple position whose tail reads a parameter the body mutated in place" do
        # Runtime `[[1], [1]]`; the nested walk answered two provably-empty `[]`.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].map do |a|
              a << w
              a
            end
          end)
        RUBY
      end

      it "floors a HashShape value whose tail reads a parameter the body mutated in place" do
        # THE REPORTED PROBE. Runtime `{ x: [1], y: [1] }`; the nested per-pair fold answered `{ x: [], y: [] }`.
        expect(dumped_type(<<~RUBY)).to eq("{ x: Dynamic[top], y: Dynamic[top] }")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            { x: [], y: [] }.transform_values do |a|
              a << w
              a
            end
          end)
        RUBY
      end

      it "no longer reports a nil receiver read out of the stale HashShape value" do
        # THE HAZARD: `r[:x].first` read `[].first`, a provable nil, and `+` was reported on correct code.
        expect(undefined_method_rules(<<~RUBY)).to be_empty
          m = Mutex.new
          v = 1
          r = m.synchronize do
            w = v
            { x: [], y: [] }.transform_values do |a|
              a << w
              a
            end
          end
          r[:x].first + 1
        RUBY
      end

      it "no longer reports a nil receiver read out of the stale Tuple position" do
        expect(undefined_method_rules(<<~RUBY)).to be_empty
          m = Mutex.new
          v = 1
          r = m.synchronize do
            w = v
            [[], []].map do |a|
              a << w
              a
            end
          end
          r[0].first + 1
        RUBY
      end

      it "still reports the nil receiver when the tail ignores its prefix" do
        # The must-fire sibling: nothing mutates `a`, so the value really is `[]` and `.first` really is nil.
        expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
          m = Mutex.new
          v = 1
          r = m.synchronize do
            w = v
            { x: [], y: [] }.transform_values do |a|
              q = w
              a
            end
          end
          r[:x].first + 1
        RUBY
      end

      it "floors a flat_map whose flattened positions were the pre-state" do
        # Runtime `[1, 1]`; flattening two stale `[]` answered a provably-empty `[]`. The floored positions are no
        # Tuple, so the assembler declines and the dispatcher answers.
        expect(dumped_type(<<~RUBY)).to eq("Array[Dynamic[top]]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].flat_map do |a|
              a << w
              a
            end
          end)
        RUBY
      end

      it "reads a captured local the body mutates in place through its in-place widening, not the floor" do
        # Runtime `[[1, 1], [1, 1]]` — both positions are `out` itself. Before #1203 nothing re-answered a name
        # the body never rebinds, so the floor took it; the in-place widening evaluates no body, so it holds
        # under the suppression too, and the name counts as answered.
        expect(dumped_type(<<~RUBY)).to eq("[Array[Dynamic[top]], Array[Dynamic[top]]]")
          m = Mutex.new
          v = 1
          out = []
          dump_type(m.synchronize do
            w = v
            [1, 2].map do |e|
              out << w
              out
            end
          end)
        RUBY
      end

      it "keeps a Tuple position whose tail ignores its prefix exact" do
        expect(dumped_type(<<~RUBY)).to eq("[5, 5]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [1, 2].map do |e|
              q = e + w
              5
            end
          end)
        RUBY
      end

      it "keeps a single-statement Tuple body exact" do
        expect(dumped_type(<<~RUBY)).to eq("[2, 3]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [1, 2].map { |e| e + w }
          end)
        RUBY
      end

      it "keeps a HashShape value whose tail ignores its prefix exact" do
        expect(dumped_type(<<~RUBY)).to eq("{ x: 10, y: 20 }")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            { x: 1, y: 2 }.transform_values do |e|
              q = w
              e * 10
            end
          end)
        RUBY
      end

      it "keeps a HashShape key fold whose tail ignores its prefix exact" do
        expect(dumped_type(<<~RUBY)).to eq('{ "a": 1, "b": 2 }')
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            { a: 1, b: 2 }.transform_keys do |k|
              q = w
              k.to_s
            end
          end)
        RUBY
      end

      it "threads the same body when the outer tail does not read its own prefix" do
        # The outer body is not threaded, so nothing suppresses the inner fold and every pair threads its own
        # mutation — the same answer as with no outer block at all.
        expect(dumped_type(<<~RUBY)).to eq("{ x: Array[Dynamic[top] | Integer], y: Array[Dynamic[top] | Integer] }")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            { x: [], y: [] }.transform_values do |a|
              a << v
              a
            end
          end)
        RUBY
      end

      it "floors the fold when the outer tail reads the local the fold's result was assigned to" do
        # The most idiomatic trigger: `y = fold; y` threads the outer body although the fold reads no outer
        # binding, so the fold is typed under the suppression all the same.
        expect(undefined_method_rules(<<~RUBY)).to be_empty
          m = Mutex.new
          v = 1
          r = m.synchronize do
            y = { x: [], y: [] }.transform_values do |a|
              a << v
              a
            end
            y
          end
          r[:x].first + 1
        RUBY
      end

      it "answers a key fold whose tail reads a rebound key parameter with the plain Hash floor" do
        # Runtime `{ "a1" => 1, "b1" => 2 }`; the nested per-pair fold answered `{ a: 1, b: 2 }`. Declining would
        # hand the keys to the dispatcher, whose block-return pass reads them tail-only as the same `:a | :b`.
        expect(dumped_type(<<~RUBY)).to eq("Hash[Dynamic[top], 1 | 2]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            { a: 1, b: 2 }.transform_keys do |k|
              k = "\#{k}\#{w}"
              k
            end
          end)
        RUBY
      end

      it "answers an undecided key fold from the keys it typed instead of declining into a tail-only pass" do
        # Runtime `{ "k1" => 1 }`. `buf` is answered by its in-place widening, so no floor fires, but the key is
        # no single `Constant`; a decline handed it to the dispatcher, whose tail-only pass read `buf` as `"k"`.
        expect(dumped_type(<<~RUBY)).to eq("Hash[String, 1]")
          m = Mutex.new
          v = 1
          buf = +"k"
          dump_type(m.synchronize do
            w = v
            { a: 1 }.transform_keys do |k|
              buf << w.to_s
              buf
            end
          end)
        RUBY
      end

      it "answers a key a rebound counter spells from the keys it typed too" do
        # Runtime `{ "a1" => 1, "b2" => 2 }`; the dispatcher's tail-only pass read `i` as `0`.
        expect(dumped_type(<<~RUBY)).to eq("Hash[String, 1 | 2]")
          m = Mutex.new
          v = 1
          i = 0
          dump_type(m.synchronize do
            w = v
            { a: 1, b: 2 }.transform_keys do |k|
              i += w
              k.to_s + i.to_s
            end
          end)
        RUBY
      end

      it "keeps an empty shape's exact fold, since no pair is typed" do
        expect(dumped_type(<<~RUBY)).to eq("{}")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            {}.transform_keys do |k|
              k = "\#{k}\#{w}"
              k
            end
          end)
        RUBY
      end

      it "answers a nested select whose predicate read the pre-state with the filter floor" do
        # Runtime `[[1], [1]]`; the tail-only predicate read `[].any?` and the fall-through answered `[]`.
        expect(dumped_type(<<~RUBY)).to eq("Array[[]]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].select do |a|
              a << w
              a.any?
            end
          end)
        RUBY
      end

      it "reads an instance variable the body mutates in place through its in-place widening too" do
        expect(dumped_type(<<~RUBY)).to eq("[Array[Dynamic[top]], Array[Dynamic[top]]]")
          class Buffer
            def run
              m = Mutex.new
              v = 1
              @buf = []
              dump_type(m.synchronize do
                w = v
                [1, 2].map do |e|
                  @buf << w
                  @buf
                end
              end)
            end
          end
        RUBY
      end

      it "keeps the structure around a rebound captured local, which the suppression floors by name" do
        expect(dumped_type(<<~RUBY)).to eq("[[Dynamic[top], 1], [Dynamic[top], 2]]")
          m = Mutex.new
          v = 1
          total = 0
          dump_type(m.synchronize do
            w = v
            [1, 2].map do |e|
              total += w
              [total, e]
            end
          end)
        RUBY
      end

      it "keeps the structure around a body-local, which tail-only already reads as Dynamic[top]" do
        # The body-local has no entry binding, so tail-only is sound for it; flooring the position would erase
        # the `raw:` value it cannot affect.
        expect(dumped_type(<<~RUBY)).to eq("[{ value: Dynamic[top], raw: 1 }, { value: Dynamic[top], raw: 2 }]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [1, 2].map do |e|
              x = e * w
              { value: x, raw: e }
            end
          end)
        RUBY
      end

      it "keeps a body that leaves through a `next` exact, since the join evaluates it whole" do
        expect(dumped_type(<<~RUBY)).to eq("[Array[Dynamic[top] | Integer], Array[Dynamic[top] | Integer]]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].map do |a|
              a << w
              w.nil? ? (next []) : a
            end
          end)
        RUBY
      end
    end

    # The same suppression types every other nested block tail-only too: the dispatcher's generic block-return pass,
    # and the `inject` fold, which shares its body typing. The answer is the per-name one the folds give a captured
    # local — a name the prefix rebinds reads `Dynamic[top]`, one it only mutates in place reads its in-place
    # widening — extended to every name no #587 (b) binding answers: a block parameter, and a capture of a block the
    # call runs at most once, of an iterator that discards its block's value or that the catalogue does not know, or
    # of the `inject` fold, and an instance variable on its class-wide seed. A name whose widening declines keeps its
    # entry binding, because threading would have kept it too; a class-wide seed already holds the prefix's rebinds,
    # so only its in-place mutations widen it.
    describe "(2), nested: the generic block-return pass under the same suppression" do
      it "widens a parameter the body mutated in place under a HashShape map" do
        # Runtime `[[1], [1]]`; the pass read `a` at its entry `[]`.
        expect(dumped_type(<<~RUBY)).to eq("Array[Array[Dynamic[top]]]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            { x: [], y: [] }.map do |_k, a|
              a << w
              a
            end
          end)
        RUBY
      end

      it "no longer reports a nil receiver read out of the stale parameter" do
        # THE HAZARD: `a.first` read `[].first`, a provable nil, and `+` was reported on correct code.
        expect(undefined_method_rules(<<~RUBY)).to be_empty
          m = Mutex.new
          v = 1
          r = m.synchronize do
            w = v
            { x: [], y: [] }.map do |_k, a|
              a << w
              a
            end
          end
          r.each { |a| a.first + 1 }
        RUBY
      end

      it "floors a parameter the body rebinds under a nominal map" do
        # Runtime `Array[String]`; the pass read `e` at its entry `Integer`.
        expect(dumped_type(<<~RUBY)).to eq("Array[Dynamic[top]]")
          m = Mutex.new
          v = 1
          xs = Array.new(rand(3)) { |i| i }
          dump_type(m.synchronize do
            w = v
            xs.map do |e|
              e = e.to_s + w.to_s
              e
            end
          end)
        RUBY
      end

      it "floors the rebound name only, keeping the structure around it" do
        expect(dumped_type(<<~RUBY)).to eq("Array[[Dynamic[top], 1]]")
          m = Mutex.new
          v = 1
          xs = Array.new(rand(3)) { |i| i }
          dump_type(m.synchronize do
            w = v
            xs.map do |e|
              e = e.to_s
              [e, w]
            end
          end)
        RUBY
      end

      it "floors a captured local a block the call runs once rebinds" do
        # Runtime `1`. `synchronize` runs its block once, so the pass lays no captured binding and read `i` as `0`.
        expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
          m = Mutex.new
          v = 1
          i = 0
          dump_type(m.synchronize do
            w = v
            m.synchronize do
              i += w
              i
            end
          end)
        RUBY
      end

      it "no longer reports the condition the stale counter folded" do
        # THE HAZARD: `k == 0` folded to `true`, and the rule fired on a condition Ruby answers `false`.
        expect(flow_rules(<<~RUBY)).to be_empty
          m = Mutex.new
          v = 1
          i = 0
          k = m.synchronize do
            w = v
            m.synchronize do
              i += w
              i
            end
          end
          puts "zero" if k == 0
        RUBY
      end

      it "floors an instance variable a block the call runs once rebinds" do
        expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
          class Counter
            def run
              m = Mutex.new
              v = 1
              @n = 0
              dump_type(m.synchronize do
                w = v
                m.synchronize do
                  @n += w
                  @n
                end
              end)
            end
          end
        RUBY
      end

      it "keeps an instance variable on its class-wide seed, which already holds the prefix's write" do
        # `@mode` enters on `:fast | :slow`, the union of every write in the class, so the tail is not stale.
        expect(dumped_type(<<~RUBY)).to eq("[:fast | :slow, 1]")
          class Mode
            def initialize
              @mode = :fast
            end

            def run
              m = Mutex.new
              v = 1
              dump_type(m.synchronize do
                w = v
                m.synchronize do
                  @mode = :slow
                  [@mode, w]
                end
              end)
            end
          end
        RUBY
      end

      it "widens an instance variable on its class-wide seed that the body mutates in place" do
        # Runtime `"k1"`. `<<` is no write, so the seed `"k"` does not hold it.
        expect(dumped_type(<<~RUBY)).to eq("String")
          class Buf
            def initialize
              @out = +"k"
            end

            def append(v)
              m = Mutex.new
              dump_type(m.synchronize do
                w = v
                m.synchronize do
                  @out << w.to_s
                  @out
                end
              end)
            end
          end
        RUBY
      end

      it "no longer reports the condition the stale class-wide seed folded" do
        expect(flow_rules(<<~RUBY)).to be_empty
          class Buf
            def initialize
              @out = +"k"
            end

            def append(v)
              m = Mutex.new
              r = m.synchronize do
                w = v
                m.synchronize do
                  @out << w.to_s
                  @out
                end
              end
              puts "unchanged" if r == "k"
            end
          end
        RUBY
      end

      it "widens the class-wide seed of an instance variable the body both rebinds and mutates" do
        # The seed `"a" | "k"` holds the rebind's `"a"` but not the append after it: runtime `"a1"`.
        expect(dumped_type(<<~RUBY)).to eq("String")
          class Buf
            def initialize
              @out = +"k"
            end

            def reset(v)
              m = Mutex.new
              dump_type(m.synchronize do
                w = v
                m.synchronize do
                  @out = +"a"
                  @out << w.to_s
                  @out
                end
              end)
            end
          end
        RUBY
      end

      it "floors a captured local an iterator outside the catalogue runs" do
        # Runtime `2`; no #587 (b) binding is laid for an iterator the catalogue does not know.
        expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
          class Pair
            def each_twice
              yield
              yield
            end
          end
          m = Mutex.new
          v = 1
          tot = 0
          dump_type(m.synchronize do
            w = v
            Pair.new.each_twice do
              tot += w
              tot
            end
          end)
        RUBY
      end

      it "re-answers an accumulator the inject fold's block rebinds" do
        # Runtime `6`. The fold types its block through the same pass, which read `acc` at the seed `0`.
        expect(dumped_type(<<~RUBY)).to eq("0 | Dynamic[top]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [1, 2, 3].inject(0) do |acc, e|
              acc += e + w - 1
              acc
            end
          end)
        RUBY
      end

      it "widens a captured String literal the body appends to" do
        # Runtime `"k1"`; the pass read `buf` at its entry `"k"`.
        expect(dumped_type(<<~RUBY)).to eq("String")
          m = Mutex.new
          v = 1
          buf = +"k"
          dump_type(m.synchronize do
            w = v
            m.synchronize do
              buf << w.to_s
              buf
            end
          end)
        RUBY
      end

      it "widens a global the body appends to" do
        # Runtime `"k1"`; the pass read `$g` at its entry `"k"`, since the receiver scan did not collect a global.
        expect(dumped_type(<<~RUBY)).to eq("String")
          $g = +"k"
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            m.synchronize do
              $g << w.to_s
              $g
            end
          end)
        RUBY
      end

      it "no longer reports the condition the stale global folded" do
        expect(flow_rules(<<~RUBY)).to be_empty
          $g = +"k"
          m = Mutex.new
          v = 1
          r = m.synchronize do
            w = v
            m.synchronize do
              $g << w.to_s
              $g
            end
          end
          puts "same" if r == "k"
        RUBY
      end

      it "still reports the condition when the tail reads a global the body does not touch" do
        expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
          $g = +"k"
          $h = +"k"
          m = Mutex.new
          v = 1
          r = m.synchronize do
            w = v
            m.synchronize do
              $h << w.to_s
              $g
            end
          end
          puts "same" if r == "k"
        RUBY
      end

      it "widens a class variable the body appends to" do
        expect(dumped_type(<<~RUBY)).to eq("String")
          class Buf
            def run(v)
              @@out = +"k"
              m = Mutex.new
              dump_type(m.synchronize do
                w = v
                m.synchronize do
                  @@out << w.to_s
                  @@out
                end
              end)
            end
          end
        RUBY
      end

      it "floors an `it` parameter the body mutated in place under a Tuple map, as it floors `|a|`" do
        # Runtime `[[1], [1]]`; the fold read `it` at its entry `[]` and answered `[[], []]`.
        expected = "[Dynamic[top], Dynamic[top]]"
        expect(dumped_type(<<~RUBY)).to eq(expected)
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].map do
              it << w
              it
            end
          end)
        RUBY
        expect(dumped_type(<<~RUBY)).to eq(expected)
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].map do |a|
              a << w
              a
            end
          end)
        RUBY
      end

      it "leaves the body's `it` alone when only a nested block's own `it` is mutated" do
        # Runtime `[[], []]`. The nested `each` block's `it` is that block's parameter, so the body's `it` is never
        # mutated; filing both under `:it` floored the body's to `Dynamic[top]`. The `|a|` spelling never confused them.
        expect(dumped_type(<<~RUBY)).to eq("[[], []]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].map do
              [[]].each { it << w }
              it
            end
          end)
        RUBY
      end

      it "floors the body's `it` mutated inside a loop, which binds no `it` of its own" do
        # Runtime `[[1], [1]]`: a `for` body runs in the block's own scope, so its `it` is the body's.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].map do
              for i in [1]
                it << w
              end
              it
            end
          end)
        RUBY
      end

      it "leaves the body's `it` alone when only a nested lambda's own `it` is mutated" do
        # Runtime `[[], []]`: the lambda's `it` is the `[]` it is called with.
        expect(dumped_type(<<~RUBY)).to eq("[[], []]")
          m = Mutex.new
          v = 1
          dump_type(m.synchronize do
            w = v
            [[], []].map do
              -> { it << w }.call([])
              it
            end
          end)
        RUBY
      end

      it "keeps a nominal String pre-state the append cannot move" do
        # The must-hold sibling: `String` is what the threaded body answers too, so tail-only was never stale.
        expect(dumped_type(<<~RUBY)).to eq("String")
          m = Mutex.new
          v = 1
          s = String.new
          dump_type(m.synchronize do
            w = v
            m.synchronize do
              s << w.to_s
              s
            end
          end)
        RUBY
      end

      it "keeps a precise nominal Array whose widening declines" do
        # `Array[String]` is a claim the widening may not grow, so the threaded body keeps it as well.
        expect(dumped_type(<<~RUBY)).to eq("Array[String]")
          m = Mutex.new
          v = 1
          ks = ENV.keys
          dump_type(m.synchronize do
            w = v
            m.synchronize do
              ks << w.to_s
              ks
            end
          end)
        RUBY
      end

      it "keeps a tail that ignores its prefix exact" do
        expect(dumped_type(<<~RUBY)).to eq("Array[5]")
          m = Mutex.new
          v = 1
          xs = Array.new(rand(3)) { |i| i }
          dump_type(m.synchronize do
            w = v
            xs.map do |e|
              q = e + w
              5
            end
          end)
        RUBY
      end

      it "keeps a single-statement body exact" do
        expect(dumped_type(<<~RUBY)).to eq("Array[Integer]")
          m = Mutex.new
          v = 1
          xs = Array.new(rand(3)) { |i| i }
          dump_type(m.synchronize do
            w = v
            xs.map { |e| e + w }
          end)
        RUBY
      end

      it "still reports the condition when the tail ignores the counter it rebinds" do
        # The must-fire sibling: the tail reads a fresh `0`, so `k == 0` really is always true.
        expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
          m = Mutex.new
          v = 1
          i = 0
          k = m.synchronize do
            w = v
            m.synchronize do
              i += w
              0
            end
          end
          puts "zero" if k == 0
        RUBY
      end

      it "threads the same body when nothing suppresses it" do
        # No enclosing threaded body, so the pass evaluates the prefix and reads what it stored.
        expect(dumped_type(<<~RUBY)).to eq("Array[Array[Dynamic[top] | Integer]]")
          v = 1
          dump_type({ x: [], y: [] }.map do |_k, a|
            a << v
            a
          end)
        RUBY
      end
    end

    describe "(3) a compound write as the block's tail" do
      it "types the map result as the counter's converged type" do
        # Runtime `[1, 2]`. The pin answered `[1, 1]` because the expression typer read a compound write as
        # its rvalue alone, whatever the target held.
        expect(dumped_type("total = 0\ndump_type([1, 2].map { total += 1 })")).to eq("[Integer, Integer]")
      end

      it "stops the always-truthy firing on the second position" do
        expect(flow_rules(<<~RUBY)).to be_empty
          total = 0
          r = [1, 2].map { total += 1 }
          puts "x" if r.last == 1
        RUBY
      end

      it "keeps the straight-line compound write folded" do
        # The evaluator's own answer must not move: `total` is `15` after the write, and so is the write.
        expect(dumped_type("total = 10\ndump_type(total += 5)")).to eq("15")
      end
    end

    # The index sibling of (3). The expression typer read `h[k] += v` / `||=` / `&&=` as the rvalue alone, so
    # a block whose tail is one answered `v` at every position whatever the slot held.
    describe "an index compound write as the block's tail" do
      it "types a counter-hash tally as the stored sum, not the increment" do
        # Runtime `[1, 1, 2]`. The rvalue answer was `[1, 1, 1]`.
        expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer, Integer]")
          counts = Hash.new(0)
          dump_type(%w[a b a].map { |w| counts[w] += 1 })
        RUBY
      end

      it "stops the always-truthy firing on the tally" do
        expect(flow_rules(<<~RUBY)).to be_empty
          counts = Hash.new(0)
          r = %w[a b a].map { |w| counts[w] += 1 }
          puts "x" if r.last == 1
        RUBY
      end

      it "keeps a truthy slot's value in a `||=` tail" do
        # Runtime `["x"]`: the slot is truthy, so `||=` stores nothing and answers it. The slot's `String` stays
        # in the answer; its `"x"` pin does not, because the block stores into `seen` and every position reads
        # the in-place widening of it (the same binding a longer receiver's later positions need).
        expect(dumped_type(<<~RUBY)).to eq("[3 | Dynamic[top] | String]")
          seen = { a: "x" }
          dump_type([:a].map { |k| seen[k] ||= 3 })
        RUBY
      end

      it "stops the always-truthy firing on a `||=` tail that keeps the slot" do
        expect(flow_rules(<<~RUBY)).to be_empty
          seen = { a: "x" }
          r = [:a].map { |k| seen[k] ||= 3 }
          puts "x" if r.first == 3
        RUBY
      end

      it "types a straight-line index compound write in argument position as the stored value" do
        expect(dumped_type("h = { a: 1 }\ndump_type(h[:a] += 1)")).to eq("2")
      end

      it "types an untracked slot's `+=` tail as untyped, not the increment" do
        # `c` is a parameter, so nothing is known of `c[x]`; the rvalue answer pinned both positions to `1`.
        expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
          def tally(c)
            dump_type([1, 2].map { |x| c[x] += 1 })
          end
        RUBY
      end

      it "stops the always-truthy firing on an untracked slot's `+=` tail" do
        expect(flow_rules(<<~RUBY)).to be_empty
          def tally(c)
            r = [1, 2].map { |x| c[x] += 1 }
            puts "x" if r.last == 1
          end
        RUBY
      end
    end

    describe "(4) straight-line String mutation" do
      it "widens a mutated string literal binding" do
        expect(dumped_type("s = +\"ab\"\ns << \"c\"\ndump_type(s)")).to eq("String")
      end

      it "stops the always-truthy firing on the mutated value" do
        expect(flow_rules(<<~RUBY)).to be_empty
          s = +"ab"
          s << "c"
          puts "x" if s == "ab"
        RUBY
      end

      it "leaves an unmutated string literal pinned" do
        expect(dumped_type("s = +\"ab\"\ndump_type(s)")).to eq("\"ab\"")
      end

      it "leaves a non-mutating sibling call pinned" do
        # `upcase` returns a new String; only the bang form rewrites the receiver.
        expect(dumped_type("s = +\"ab\"\ns.upcase\ndump_type(s)")).to eq("\"ab\"")
      end

      # The block-return threading above only helps a global or class variable once the straight-line widening the
      # threaded body runs names one as well; with only the local and ivar rows it kept the literal here too.
      it "stops the always-truthy firing on a mutated global" do
        expect(flow_rules(<<~RUBY)).to be_empty
          $s = +"ab"
          $s << "c"
          puts "x" if $s == "ab"
        RUBY
      end

      it "still reports the condition on an unmutated global" do
        expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
          $s = +"ab"
          $t = +"ab"
          $t << "c"
          puts "x" if $s == "ab"
        RUBY
      end

      it "stops the always-truthy firing on a mutated class variable" do
        expect(flow_rules(<<~RUBY)).to be_empty
          class Buf
            def run
              @@s = +"ab"
              @@s << "c"
              puts "x" if @@s == "ab"
            end
          end
        RUBY
      end

      it "widens a mutated `it` parameter" do
        expect(dumped_type("[+\"ab\"].each do\n  it << \"c\"\n  dump_type(it)\nend")).to eq("String")
      end

      # A write evaluates to the variable it writes, so `(@@c ||= []) << 1` mutates `@@c`. The local and
      # instance-variable spellings were aliased first; the class-variable and global ones kept the `[]` the `||=`
      # stored, and `@@c.first.succ` then reported a nil receiver on code whose `@@c.first` is `1`.
      it "widens a class variable and a global written in the mutated receiver itself" do
        expect(undefined_method_rules(<<~RUBY)).to be_empty
          class Reg
            def add_cvar
              @@c = nil
              (@@c ||= []) << 1
              @@c.first.succ
            end

            def add_global
              $gc = nil
              ($gc ||= []) << 1
              $gc.first.succ
            end
          end
        RUBY
      end

      it "still reports the nil receiver when the write lands on another class variable or global" do
        # The read variable starts as an empty literal, so naming it by mistake would widen it and silence `succ`.
        expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method", "call.undefined-method"])
          class Reg
            def add_cvar
              @@c = []
              @@d = nil
              (@@d ||= []) << 1
              @@c.first.succ
            end

            def add_global
              $gc = []
              $gd = nil
              ($gd ||= []) << 1
              $gc.first.succ
            end
          end
        RUBY
      end

      # The widening joins the pushed value only when it knows the receiver names a carrier it will grow
      # (`MutationWidening.joinable_receiver?`); a kind that check skipped widened to a bare `Array[Dynamic[top]]`.
      it "joins the pushed value into a mutated global, class variable and `it` parameter" do
        expect(dumped_type("$acc = []\n$acc << 1\ndump_type($acc)")).to eq("Array[Dynamic[top] | Integer]")
        expect(dumped_type(<<~RUBY)).to eq("Array[Dynamic[top] | Integer]")
          class Acc
            def run
              @@acc = []
              @@acc << 1
              dump_type(@@acc)
            end
          end
        RUBY
        expect(dumped_type("[[]].each do\n  it << 1\n  dump_type(it)\nend")).to eq("Array[Dynamic[top] | Integer]")
      end
    end
  end

  # The HashShape twin of #587 (b). `transform_values` / `transform_keys` over a closed `HashShape` type the
  # block once per pair, every pair from the same entry scope, so a captured local the body rebinds was read at
  # its first-iteration value at every pair: `{ x: 1, y: 1 }` for a block whose runtime values are `{ x: 1,
  # y: 2 }`. The per-pair fold now takes the per-element fold's entry binding, the parameter bound to the
  # union of the values (or keys) for the fixpoint.
  describe "captured outer locals the body rebinds under the HashShape per-pair fold" do
    it "widens a rebound counter at every value pair" do
      # THE REPORTED PROBE. Before the fix this answered `{ x: 1, y: 1 }`.
      expect(dumped_type(<<~RUBY)).to eq("{ x: Integer, y: Integer }")
        total = 0
        dump_type({ x: 1, y: 2 }.transform_values { |e| total += 1 })
      RUBY
    end

    it "no longer reports the condition the first-iteration pin used to fold" do
      # THE HAZARD: `r[:y] == 1` folded to `Constant[true]` off the pinned `{ x: 1, y: 1 }`; it is `2 == 1`.
      expect(flow_rules(<<~RUBY)).to be_empty
        total = 0
        r = { x: 1, y: 2 }.transform_values { |e| total += 1 }
        puts "x" if r[:y] == 1
      RUBY
    end

    it "still reports the condition when the per-pair fold is exact" do
      # The must-fire sibling: a body that rebinds nothing keeps its exact per-pair values.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        r = { x: 1, y: 2 }.transform_values { |e| e }
        puts "x" if r[:y] == 2
      RUBY
    end

    it "widens an accumulator fed by the block parameter" do
      # `{ x: 1, y: 3 }` at runtime; the pin answered `{ x: 1, y: 2 }`, the value itself.
      expect(dumped_type(<<~RUBY)).to eq("{ x: Integer, y: Integer }")
        total = 0
        dump_type({ x: 1, y: 2 }.transform_values do |e|
          total += e
          total
        end)
      RUBY
    end

    it "widens past the Tuple fold's arity cap, which the per-pair fold does not have" do
      # `45` at `:k9` at runtime; the pin answered `9`. No cap means no above-the-cap floor either: every pair
      # threads its full body, and the fixpoint's cost does not scale with the pair count.
      pairs = (1..9).map { |n| "k#{n}: #{n}" }.join(", ")
      expected = (1..9).map { |n| "k#{n}: Integer" }.join(", ")
      expect(dumped_type(<<~RUBY)).to eq("{ #{expected} }")
        total = 0
        dump_type({ #{pairs} }.transform_values do |e|
          total += e
          total
        end)
      RUBY
    end

    it "widens the bang form through the same fold" do
      expect(dumped_type(<<~RUBY)).to eq("{ x: Integer, y: Integer }")
        total = 0
        h = { x: 1, y: 2 }
        dump_type(h.transform_values! { |e| total += 1 })
      RUBY
    end

    it "widens a captured hash the body stores into at every pair" do
      # The in-place half of the same entry binding. `{ x: 1, y: 2 }` at runtime; the entry `{ a: 0 }` answered
      # `{ x: 0, y: 0 }` for the read-back at every pair.
      expect(dumped_type(<<~RUBY)).to eq("{ x: Dynamic[top] | Integer, y: Dynamic[top] | Integer }")
        g = { a: 0 }
        dump_type({ x: 1, y: 2 }.transform_values do |e|
          g[:a] += 1
          g[:a]
        end)
      RUBY
    end

    it "keeps an unmutated captured hash read by key exact at every pair" do
      expect(dumped_type(<<~RUBY)).to eq("{ x: 0, y: 0 }")
        g = { a: 0 }
        dump_type({ x: 1, y: 2 }.transform_values { |e| g[:a] })
      RUBY
    end

    it "keeps a pair whose tail reads a captured local the body does not rebind" do
      expect(dumped_type(<<~RUBY)).to eq("{ x: 5, y: 5 }")
        total = 0
        k = 5
        dump_type({ x: 1, y: 2 }.transform_values do |e|
          total += e
          k
        end)
      RUBY
    end

    it "keeps a value fold that ignores the rebound counter" do
      expect(dumped_type(<<~RUBY)).to eq("{ x: 10, y: 20 }")
        seen = 0
        dump_type({ x: 1, y: 2 }.transform_values do |e|
          seen += 1
          e * 10
        end)
      RUBY
    end

    it "declines a key fold whose new keys the pinned counter spelled" do
      # `{ "a1" => 1, "b2" => 2 }` at runtime. The pin read `i` as `1` at both pairs and folded `{ "a1": 1,
      # "b1": 2 }` — two distinct constants, so the collision decline did not catch it. Widened, the new key is
      # no single `Constant`, so the tier declines to the dispatcher, whose generic block-return pass lays the
      # same captured binding and reads the key as a `String` rather than the entry scope's `"a1"`.
      expect(dumped_type(<<~RUBY)).to eq("Hash[String, 1 | 2]")
        i = 0
        dump_type({ a: 1, b: 2 }.transform_keys do |k|
          i += 1
          k.to_s + i.to_s
        end)
      RUBY
    end

    it "keeps a key fold that ignores the rebound counter" do
      expect(dumped_type(<<~RUBY)).to eq('{ "a": 1, "b": 2 }')
        seen = 0
        dump_type({ a: 1, b: 2 }.transform_keys do |k|
          seen += 1
          k.to_s
        end)
      RUBY
    end

    it "floors the rebound local when the fold is nested inside a threaded body" do
      expect(dumped_type(<<~RUBY)).to eq("{ x: Dynamic[top], y: Dynamic[top] }")
        m = Mutex.new
        total = 0
        dump_type(m.synchronize do
          v = 1
          { x: 1, y: 2 }.transform_values do |e|
            total += v
            total
          end
        end)
      RUBY
    end

    it "widens a rebound instance variable at every value pair" do
      # The instance variables the per-element binding covers move per pair too; the pin answered `{ x: 1,
      # y: 1 }`.
      expect(dumped_type(<<~RUBY)).to eq("{ x: Integer, y: Integer }")
        class Counter
          def run
            @t = 0
            dump_type({ x: 1, y: 2 }.transform_values { |e| @t += 1 })
          end
        end
      RUBY
    end

    it "keeps an instance variable the body does not rebind exact at every value pair" do
      expect(dumped_type(<<~RUBY)).to eq("{ x: 5, y: 5 }")
        class Counter
          def run
            @t = 0
            @u = 5
            dump_type({ x: 1, y: 2 }.transform_values do |e|
              @t += e
              @u
            end)
          end
        end
      RUBY
    end
  end

  # The #587 (b) fixpoint reads each pass's exit binding out of `StatementEvaluator`, and the evaluator carries a
  # rebind into that exit only from the positions it threads: a statement, an assignment's value, a branch, a
  # loop, an `&&` / `||` operand. A rebind inside a call's receiver or arguments, a literal, an interpolation,
  # an index or a `when` condition, a rebind of an instance variable inside a nested block, and a rebind that a
  # later `next` can leave the iteration with never reaches it. #617's unmoved-pin floor caught such a name only
  # while nothing else moved its binding; a threaded `||=` or a guarded write elsewhere moves it, and the pin
  # came back. A name rebound in any of those positions is floored whatever the fixpoint converged to.
  describe "rebinds the body evaluator does not thread under the per-element fold" do
    it "floors a counter rebound inside an expression after a threaded `||=` moved it" do
      # THE REPORTED PROBE. Runtime answer `2`; the `||=` moved the exit binding to `0`, so the unmoved-pin floor
      # let the pin through, every predicate read `0 + 1 == 2`, and `find` answered `nil`.
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        seen = nil
        dump_type([1, 2].find { |e| seen ||= 0; (seen += 1) == 2 })
      RUBY
    end

    it "no longer reports the always-falsey condition the moved pin folded" do
      expect(flow_rules(<<~RUBY)).to be_empty
        seen = nil
        r = [1, 2].find { |e| seen ||= 0; (seen += 1) == 2 }
        puts "found" if r
      RUBY
    end

    it "floors a counter a guarded statement write moves" do
      # `seen = 5 if …` is threaded, so the exit binding joins `5` and stops being the seed.
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        seen = 0
        dump_type([1, 2].find { |e| seen = 5 if rand > 2; (seen += 1) == 2 })
      RUBY
    end

    it "floors a counter rebound inside a call argument" do
      # Runtime `[1, 2]`; the pin answered `[0, 0]`. The scan floors `s` across passes, and since issue #1223 the
      # body threads `s += 1` over that floor too, so no position keeps the `0` it can never hold at the tail.
      expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top]]")
        def log(x) = x

        def run
          s = nil
          dump_type([1, 2].map { |e| s ||= 0; log(s += 1); s })
        end
      RUBY
    end

    it "keeps the joined binding of a counter rebound on a branch a `next` leaves from" do
      # Runtime `[0, 1]`. The pass's exit joins the `next` path (`StatementEvaluator#evaluate_invocation`), so
      # the scan leaves the rebind threaded and the fixpoint answers it; the pin answered `[0, 0]`.
      expect(dumped_type(<<~RUBY)).to eq("[0 | Integer, 0 | Integer]")
        seen = nil
        dump_type([1, 2].map { |e| seen ||= 0; if e == 1; seen += 1; next 0; end; seen })
      RUBY
    end

    it "keeps the nil a `next` whose guard narrows a rebound local leaves with" do
      # Runtime `[0, 0, nil]`. The fall-through alone binds `last` narrowed away from nil; the joined `next` path
      # brings the nil back, so the third position no longer reads `0 | 1 | 2`.
      expect(dumped_type(<<~RUBY)).to eq("[0 | 1 | 2 | nil, 0 | 1 | 2 | nil, 0 | 1 | 2 | nil]")
        last = 0
        dump_type([1, nil, 2].map { |e| r = last; last = e; next 0 if last.nil?; r })
      RUBY
    end

    it "keeps the joined binding of a local a nested block rebinds before its own `next`" do
      # Runtime `[1, 2]`: the nested write-back joins its `next` branch, so the rebind is threaded.
      expect(dumped_type(<<~RUBY)).to eq("[0 | Integer, 0 | Integer]")
        s = nil
        dump_type([1, 2].map { |e| s ||= 0; [1, 2].each { |x| if x == 1; s += 1; next; end }; s })
      RUBY
    end

    it "floors a global a nested block rebinds" do
      # The nested write-back covers locals and instance variables, not globals. Runtime `[1, 2]`.
      expect(dumped_type(<<~RUBY)).to eq("[0 | Dynamic[top], 0 | Dynamic[top]]")
        $n = nil
        dump_type([1, 2].map { |e| $n ||= 0; [1].each { $n += 1 }; $n })
      RUBY
    end

    it "floors a local a `while` loop rebinds before its `next`" do
      # The loop's continuation does not join its `next` path. Runtime `[1, 2]`.
      expect(dumped_type(<<~RUBY)).to eq("[0 | Dynamic[top], 0 | Dynamic[top]]")
        s = nil
        dump_type([1, 2].map { |e| s ||= 0; i = 0; while i < 1; i += 1; if i == 1; s += 1; next; end; end; s })
      RUBY
    end

    it "floors an instance variable rebound inside an expression after a threaded `||=`" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        class Counter
          def run
            @seen = nil
            dump_type([1, 2].find { |e| @seen ||= 0; (@seen += 1) == 2 })
          end
        end
      RUBY
    end

    it "keeps the written-back binding of an instance variable a nested block rebinds" do
      # A nested block's write-back carries its instance variables too, so `@n += 1` inside it reaches the exit
      # binding. Runtime `[1, 2]`; the pin answered `[0, 0]`.
      expect(dumped_type(<<~RUBY)).to eq("[0 | Integer, 0 | Integer]")
        class Counter
          def run
            @n = nil
            dump_type([1, 2].map { |e| @n ||= 0; [1].each { @n += 1 }; @n })
          end
        end
      RUBY
    end

    it "floors the same shape under the per-pair fold" do
      expect(dumped_type(<<~RUBY)).to eq("{ x: Dynamic[top], y: Dynamic[top] }")
        def log(x) = x

        def run
          s = nil
          dump_type({ x: 1, y: 2 }.transform_values { |v| s ||= 0; log(s += 1); s })
        end
      RUBY
    end

    it "floors a global a multi-assign target rebinds" do
      # The evaluator binds a multi-assign's locals and instance variables only: `_, $last = x, x` leaves `$last`
      # on `nil`, which carries no value pin for the unmoved-pin floor to see. Runtime `2`.
      source = <<~RUBY
        $last = nil
        r = [1, 2].find { |x| prev = $last; _, $last = x, x; prev == 1 }
      RUBY
      expect(dumped_type("#{source}dump_type(r)")).to eq("1 | 2 | nil")
      expect(flow_rules("#{source}puts 'hit' if r")).to be_empty
    end

    it "floors an instance variable a `rescue =>` reference rebinds" do
      # It binds a local only. Runtime `2`.
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        class Counter
          def run
            @err = nil
            dump_type([1, 2].find do |x|
              prev = @err
              begin
                raise ArgumentError, "x"
              rescue => @err
              end
              prev
            end)
          end
        end
      RUBY
    end

    it "floors an instance variable a `for` index rebinds" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        class Counter
          def run
            @cur = nil
            dump_type([1, 2].find do |x|
              prev = @cur
              for @cur in [x]; end
              prev
            end)
          end
        end
      RUBY
    end

    it "floors a local a `while` loop rebinds before its `break`" do
      # The loop's continuation does not join the scope its `break` left with. Runtime `1`.
      source = <<~RUBY
        seen = nil
        r = [1, 2].find do |e|
          i = 0
          while i < 3
            i += 1
            if i == 2
              seen = e
              break
            end
          end
          seen == 1
        end
      RUBY
      expect(dumped_type("#{source}dump_type(r)")).to eq("1 | 2 | nil")
      expect(flow_rules("#{source}puts 'found' if r")).to be_empty
    end

    it "widens a global the body mutates in place" do
      # `$seen << x` is never a rebind, so the global needs the in-place half. Runtime `2`.
      source = <<~RUBY
        $seen = []
        r = [1, 2].find { |x| n = $seen.size; $seen << x; n == 1 }
      RUBY
      expect(dumped_type("#{source}dump_type(r)")).to eq("1 | 2 | nil")
      expect(flow_rules("#{source}puts 'hit' if r")).to be_empty
    end

    it "widens a parenthesised global the body mutates in place" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | nil")
        $gp = []
        dump_type([1, 2].find { |x| n = $gp.size; ($gp) << x; n == 1 })
      RUBY
    end

    it "keeps the fixpoint of a counter whose every rebind is threaded" do
      # The paired control: the same `||=` and `+=` as statements are both threaded, so the fixpoint is the
      # answer and nothing is floored.
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        total = nil
        dump_type([1, 2].map { |e| total ||= 0; total += 1; total })
      RUBY
    end

    it "keeps the fixpoint of a rebind that follows the `next` guard" do
      # A `next` ahead of every rebind leaves with the binding the iteration entered on, which the fixpoint
      # already holds.
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        total = 0
        dump_type([1, 2].map { |e| next 0 if e > 5; total += e; total })
      RUBY
    end

    it "keeps the fixpoint of a threaded name beside a floored one" do
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        def log(x) = x

        def run
          seen = nil
          total = 0
          dump_type([1, 2].map { |e| seen ||= 0; log(seen += 1); total += e; total })
        end
      RUBY
    end

    it "keeps a predicate fold that ignores the floored counter" do
      expect(dumped_type(<<~RUBY)).to eq("[2]")
        def log(x) = x

        def run
          seen = nil
          dump_type([1, 2].select { |e| seen ||= 0; log(seen += 1); e > 1 })
        end
      RUBY
    end
  end

  # When a fold declines — or never applies, because the receiver is no `Tuple` or closed `HashShape` — the
  # dispatcher reads ONE block-return type, typed from the call's ENTRY scope. That is the first iteration's
  # binding of every captured local and instance variable the body rebinds, so a `transform_keys` whose new key
  # a rebound flag chooses answered the first key only, and over a nominal `Array` a counter predicate folded
  # `all?` to `true` and `find` to `nil` on programs that answer otherwise. The pass now lays the #587 (b)
  # captured binding under the block's parameters before typing the body.
  describe "captured rebinds under the generic block-return pass" do
    it "keeps every key a rebound flag chooses when the per-pair key fold declines" do
      # Runtime `{ a: 1, other: 2 }`; the entry scope read `flag` as `true` and answered `Hash[:a | :b, 1 | 2]`.
      expect(dumped_type(<<~RUBY)).to eq("Hash[:a | :b | :other, 1 | 2]")
        flag = true
        dump_type({ a: 1, b: 2 }.transform_keys { |k| out = flag ? k : :other; flag = false; out })
      RUBY
    end

    it "keeps every key a rebound instance-variable counter chooses" do
      # Runtime `{ first: 1, rest: 2 }`; the entry scope answered `Hash[:first, 1 | 2]`.
      expect(dumped_type(<<~RUBY)).to eq("Hash[:first | :rest, 1 | 2]")
        class Counter
          def run
            @i = 0
            dump_type({ a: 1, b: 2 }.transform_keys { |k| @i += 1; @i == 1 ? :first : :rest })
          end
        end
      RUBY
    end

    it "types a nominal map over a rebound counter as the converged type" do
      # Runtime `[1, 2, …]`; the entry scope answered `Array[1]`.
      expect(dumped_type(<<~RUBY)).to eq("Array[Integer]")
        xs = Array.new(rand(3)) { |i| i }
        total = 0
        dump_type(xs.map { |x| total += 1; total })
      RUBY
    end

    it "no longer folds a nominal all? over a rebound counter to true" do
      # `seen == 1` is `true` only on the first element, so `all?` over two elements is `false`.
      expect(flow_rules(<<~RUBY)).to be_empty
        xs = Array.new(rand(3)) { |i| i }
        seen = 0
        r = xs.all? { |x| seen += 1; seen == 1 }
        puts "all" if r
      RUBY
    end

    it "no longer folds a nominal find over a rebound counter to nil" do
      expect(flow_rules(<<~RUBY)).to be_empty
        xs = Array.new(rand(3)) { |i| i }
        seen = 0
        r = xs.find { |x| seen += 1; seen == 2 }
        puts "found" if r
      RUBY
    end

    it "no longer folds a nominal any? over a counter rebound inside an expression" do
      expect(flow_rules(<<~RUBY)).to be_empty
        xs = Array.new(rand(3)) { |i| i }
        seen = 0
        r = xs.any? { |x| (seen += 1) == 2 }
        puts "any" if r
      RUBY
    end

    it "still folds a nominal all? whose block rebinds only block locals" do
      # The must-fire sibling: nothing captured moves, so the block really is `true` on every element.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        xs = Array.new(rand(3)) { |i| i }
        r = xs.all? { |x| k = 1; k == 1 }
        puts "all" if r
      RUBY
    end

    it "keeps the entry binding of a block `then` runs exactly once" do
      # No second run exists, so a rebind never reaches a read: runtime `5`, and `w + 1` is fine.
      source = <<~RUBY
        first = true
        w = 5.then { |n| was = first; first = false; was ? n : nil }
        dump_type(w)
        w + 1
      RUBY
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      expect(dumped_type(source)).to eq("Integer")
      expect(result.diagnostics.map(&:rule)).not_to include("call.possible-nil-receiver")
    end

    it "keeps the call type of a `tap` block whose `break` only a second run could take" do
      expect(dumped_type(<<~RUBY)).to eq("Array[Integer]")
        done = false
        dump_type([1].tap { |a| break if done; done = true })
      RUBY
    end

    it "keeps the entry binding of a block a method outside the iteration catalogue runs" do
      # `synchronize` runs its block once; the take-and-clear idiom answers the taken value.
      expect(dumped_type(<<~RUBY)).to eq('"abc"')
        buf = "abc"
        m = Mutex.new
        dump_type(m.synchronize { out = buf; buf = nil; out })
      RUBY
    end

    it "keeps the entry binding under an iterator whose receiver holds at most one element" do
      # One run at most, so `done` is still `false` when the guard reads it: runtime `[:only]` and `1`.
      expect(dumped_type(<<~RUBY)).to eq("Array[Symbol]")
        done = false
        dump_type([:only].each { |s| break if done; done = true })
      RUBY
      expect(dumped_type(<<~RUBY)).to eq("Integer")
        done = false
        dump_type(1.times { |i| break if done; done = true })
      RUBY
    end

    it "keeps a nominal map over an untouched captured local exact" do
      expect(dumped_type(<<~RUBY)).to eq("Array[5]")
        xs = Array.new(rand(3)) { |i| i }
        total = 0
        k = 5
        dump_type(xs.map { |x| total += x; k })
      RUBY
    end
  end

  # Residues of the #587 (b) name set: a class variable or a global outlives an iteration exactly as an
  # instance variable does, an attribute setter on `self` rebinds the instance variable behind it without a write
  # node, and an optimistic nil-freeness mark the body's own rebind makes belongs to the converged binding as much
  # as the call site's does.
  describe "the per-element fold's other outliving bindings" do
    it "widens a rebound global counter at every position" do
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        $g = 0
        dump_type([1, 2].map { |e| $g += 1 })
      RUBY
    end

    it "no longer reports the condition the pinned global folded" do
      expect(flow_rules(<<~RUBY)).to be_empty
        $g = 0
        r = [1, 2].map { |e| $g += 1 }
        puts "one" if r.last == 1
      RUBY
    end

    it "keeps a global the body does not rebind exact" do
      expect(dumped_type(<<~RUBY)).to eq("[0, 0]")
        $g = 0
        dump_type([1, 2].map { |e| $g })
      RUBY
    end

    it "widens a rebound class-variable counter at every position" do
      expect(dumped_type(<<~RUBY)).to eq("[Integer, Integer]")
        class Counter
          def run
            @@c = 0
            dump_type([1, 2].map { |e| @@c += 1 })
          end
        end
      RUBY
    end

    it "floors an instance variable an attribute setter on self rebinds" do
      # Runtime `[1, 2]`; `self.w =` writes `@w` through `attr_accessor`, which no write node shows.
      source = <<~RUBY
        class Counter
          attr_accessor :w

          def run
            @w = 0
            r = [1, 2].map { |e| self.w = @w + 1; @w }
            dump_type(r)
            puts "one" if r.last == 1
          end
        end
      RUBY
      expect(dumped_type(source)).to eq("[Dynamic[top], Dynamic[top]]")
      expect(flow_rules(source)).to be_empty
    end

    it "keeps an instance variable exact when self only reads the attribute" do
      expect(dumped_type(<<~RUBY)).to eq("[0, 0]")
        class Counter
          attr_accessor :w

          def run
            @w = 0
            dump_type([1, 2].map { |e| self.w; @w })
          end
        end
      RUBY
    end

    it "carries the optimistic nil-freeness mark the body's rebind makes" do
      # `v` enters nil-free for real (`5`) and leaves as `xs.first`, nil-free only optimistically; runtime
      # `[true, false]` over an empty `xs`. Without the exit mark `v.nil?` folded to `false` at the second
      # position and `unless r.last` fired always-truthy.
      source = <<~RUBY
        xs = Array.new(rand(0)) { |i| i }
        v = 5
        r = [1, 2].map { |e| out = v.nil? ? false : true; v = xs.first; out }
      RUBY
      expect(dumped_type("#{source}dump_type(r)")).to eq("[bool, bool]")
      expect(flow_rules("#{source}puts 'second missing' unless r.last")).to be_empty
    end
  end
end
