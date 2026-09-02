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
  # fold never sees: `evaluate(body).first` is the fall-through value only, and no next-value join into the
  # block return exists (`type_of_jump` types both as `Bot`). Threading such a body reports the fall-through
  # as if it were the whole answer, which is the one way this change could invent a false positive rather
  # than merely widen. The fold declines instead, which is master's answer for every shape here.
  describe "a prefix that can jump out of the block" do
    it "declines on a value-carrying `next` before the tail" do
      # THE BLOCKER. `next 5` makes the block's value 5 for that yield, and `Mutex#synchronize` is
      # `[X] () { () -> X } -> X`, so the CALL answers 5. Typing it `42` would be unsound.
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
        m = Mutex.new
        flag = [true, false].sample
        dump_type(m.synchronize do
          next 5 if flag
          v = 42
          v
        end)
      RUBY
    end

    it "declines on a value-carrying `break` before the tail" do
      # `break` is the same defect wearing different clothes: it terminates the YIELDING CALL and makes it
      # answer 5, so `42` is as unsound here as it is for `next`. Measured on master (78983b38) at review
      # time, this shape answers `Dynamic[top]` there too — declining restores master's answer rather than
      # regressing anything. (The review brief predicted `42` for this shape on master; it does not.)
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
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

    it "still declines on a value-carrying `next` ahead of the mutation" do
      # The jump-decline scan is unchanged: a `next 5` ahead of the `push` still makes the fold decline, and
      # the decline answers what master answered — the entry literal. That answer is no better than it was
      # (the runtime value is `[1]` or `5`), but the fold's contract is to never invent a NEW answer under a
      # jump it cannot join.
      expect(dumped_type(<<~RUBY)).to eq("[]")
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
    # Every diagnostic a flow rule produced for `source` — the always-truthy / always-falsey family.
    def flow_rules(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
    end

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
      expect(dumped_type(<<~RUBY)).to eq("1")
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
end
