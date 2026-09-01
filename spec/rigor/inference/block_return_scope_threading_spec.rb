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
