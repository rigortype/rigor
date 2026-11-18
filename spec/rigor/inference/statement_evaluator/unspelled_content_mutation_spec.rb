# frozen_string_literal: true

require "spec_helper"

# Issue #3340 — a content fact about a collection (`non-empty-array[T]` past an emptiness guard, a literal's shape)
# is stale once code the call site does not spell as `xs.<mutator>` has mutated it: a lambda literal's body, the back
# edge of `Kernel#loop`, a `begin` body before its `rescue`, a method on `self` that empties an instance variable,
# and a receiver handed to code the engine cannot read (`yield xs`, `[xs].each(&:clear)`, `xs.method(:clear).call`,
# `xs.instance_eval { clear }`, a `send` with a computed name). Every shape below empties the collection in Ruby
# 4.0.5, so `xs.size == 0` is true there; the engine answered `positive-int` and reported the branch as always falsey.
#
# Each example reads the fact twice: `Rigor.dump_type(xs.size)` must not answer `positive-int`, and the `== 0` branch
# must draw no `flow.always-truthy-condition`. The controls at the end pin that a guard nothing touches still narrows.
RSpec.describe "content facts past a mutation the call site does not spell", type: :runner do
  def diagnostics(source)
    analyze(files: { "code.rb" => %(require "rigor/testing"\n#{source}) }).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.qualified_rule == "dump.type"
    end
  end

  def folds(source)
    diagnostics(source).count { |diagnostic| diagnostic.qualified_rule == "flow.always-truthy-condition" }
  end

  # `source` reads `xs.size` once per method; none may still be `positive-int`, and no `== 0` may fold.
  def expect_no_stale_size(source, reads:)
    types = dumped_types(source)
    expect(types.size).to eq(reads)
    expect(types).not_to include("positive-int")
    expect(folds(source)).to eq(0)
  end

  def guard = "xs = gets.to_s.chars\n  return if xs.empty?"
  def read = "Rigor.dump_type(xs.size)\n  puts 1 if xs.size == 0"

  it "drops the fact a lambda literal's body falsifies, called after the guard" do
    expect_no_stale_size(<<~RUBY, reads: 2)
      def arrow
        #{guard}
        clear_it = -> { xs.clear }
        clear_it.call
        #{read}
      end

      def arrow_pop
        #{guard}
        drop = ->(n) { xs.pop(n) }
        drop.(2)
        #{read}
      end
    RUBY
  end

  def closures_before_guard
    <<~RUBY
      def arrow_before
        xs = gets.to_s.chars
        clear_it = -> { xs.clear }
        return if xs.empty?
        clear_it.call
        #{read}
      end

      def proc_before
        xs = gets.to_s.chars
        drop = proc { xs.pop }
        return if xs.empty?
        drop.call
        #{read}
      end

      def defined_before
        xs = gets.to_s.chars
        define_singleton_method(:zap) { xs.shift }
        self.class.define_method(:wipe) { [xs].each(&:clear) }
        return if xs.empty?
        zap
        #{read}
      end

      def enclosing_scope
        xs = gets.to_s.chars
        wipe = lambda { xs.send(:clear) }
        [1].each do
          next if xs.empty?
          wipe.call
          #{read}
        end
      end
    RUBY
  end

  # A closure made before the guard may run after it, so the guard narrows nothing ({DeferredMutation}).
  it "does not take the guard's fact for a local a closure made before the guard can empty" do
    expect_no_stale_size(closures_before_guard, reads: 4)
  end

  def harmless_closures
    <<~RUBY
      def reader_before
        xs = gets.to_s.chars
        show = -> { xs.size }
        add = -> { xs << "a" }
        return if xs.empty?
        show.call
        add.call
        Rigor.dump_type(xs.size)
      end

      def finished_before
        xs = gets.to_s.chars
        [1].each { xs.clear }
        return if xs.empty?
        Rigor.dump_type(xs.size)
      end

      def shadowed
        xs = gets.to_s.chars
        wipe = ->(xs) { xs.clear }
        return if xs.empty?
        wipe.call([1])
        Rigor.dump_type(xs.size)
      end

      def guard_inside
        xs = gets.to_s.chars
        proc do
          next if xs.empty?
          Rigor.dump_type(xs.size)
          xs.pop
        end
      end
    RUBY
  end

  it "keeps the guard's fact beside a closure that cannot empty the local, or that holds the guard" do
    expect(dumped_types(harmless_closures)).to eq(%w[positive-int positive-int positive-int positive-int])
  end

  it "drops a literal's shape a lambda literal's body falsifies" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[1 | 2]", "Hash[Symbol, 1]", "String"])
      def tuple
        xs = [1, 2]
        f = -> { xs.clear }
        f.call
        Rigor.dump_type(xs)
      end

      def shape
        h = { a: 1 }
        f = -> { h.clear }
        f.call
        Rigor.dump_type(h)
      end

      def buffer
        s = +"ab"
        f = -> { s.clear }
        f.call
        Rigor.dump_type(s)
      end
    RUBY
  end

  it "enters a `Kernel#loop` body with the fact its own back edge falsifies dropped" do
    expect_no_stale_size(<<~RUBY, reads: 2)
      def drain
        #{guard}
        loop do
          Rigor.dump_type(xs.size)
          break if xs.size == 0
          xs.pop
        end
      end

      def drain_kernel
        #{guard}
        Kernel.loop do
          Rigor.dump_type(xs.size)
          break if xs.size == 0
          xs.shift
        end
      end
    RUBY
  end

  # Unchanged, and a known limit: a `Kernel#loop` body reads a capture it rebinds at its call-site binding on every
  # pass, where a later pass holds the rebound value. Pinned so the content entry does not move it by accident.
  it "leaves a capture a `Kernel#loop` body rebinds at its call-site binding" do
    expect(dumped_types(<<~RUBY)).to eq(%w[nil])
      def rebound
        xs = gets.to_s.chars
        seen = nil
        loop do
          Rigor.dump_type(seen)
          break if xs.empty?
          seen = xs.pop
        end
      end
    RUBY
  end

  it "enters a rescue clause with the fact the `begin` body falsified dropped" do
    expect_no_stale_size(<<~RUBY, reads: 2)
      def rescued
        #{guard}
        begin
          xs.clear
          raise "x"
        rescue StandardError
          #{read}
        end
      end

      def rescued_def_body
        #{guard}
        xs.clear
        raise "x"
      rescue StandardError
        #{read}
      end
    RUBY
  end

  # A body that only removes from a closed hash shape leaves the shape with every key optional, so a read of a key
  # it may have deleted still answers its `nil` (`computed_key_presence_guard_spec.rb` holds the report); a body
  # that also stores takes the unknown store.
  it "enters a rescue clause with a hash shape's keys optional past a remover, and widened past a store" do
    expect(dumped_types(<<~RUBY)).to eq(["{ ?a: 1, ?b: 2 }", "Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]"])
      def removed
        h = { a: 1, b: 2 }
        begin
          h.delete(:a)
          raise "x"
        rescue StandardError
          Rigor.dump_type(h)
        end
      end

      def stored
        h = { a: 1 }
        begin
          h.delete(:a)
          h[:c] = 3
          raise "x"
        rescue StandardError
          Rigor.dump_type(h)
        end
      end
    RUBY
  end

  # A guard, not a pin of this change: a `begin` a `retry` targets re-enters its chain from the retry-widened entry,
  # which already joined the scope after the body's `pop`.
  it "enters a rescue clause that retries with the fact the `begin` body falsified dropped" do
    expect_no_stale_size(<<~RUBY, reads: 1)
      def retried
        #{guard}
        tries = 0
        begin
          xs.pop
          raise "x" if tries < 3
        rescue StandardError
          tries += 1
          #{read}
          retry
        end
      end
    RUBY
  end

  # A class whose `@xs` is an `Array[String]` and whose `reset!` empties it, with `methods` as its other methods.
  def holder(methods)
    <<~RUBY
      class Holder
        def initialize
          @xs = gets.to_s.chars
        end

        def reset! = @xs.clear

        def count = @xs.size

        def add(x) = @xs << x

      #{methods}
      end
    RUBY
  end

  it "drops the fact of an instance variable a method on `self` empties" do
    ivar_read = "Rigor.dump_type(@xs.size)\n  puts 1 if @xs.size == 0"
    expect_no_stale_size(holder(<<~RUBY), reads: 3)
      def direct
        return if @xs.empty?
        reset!
        #{ivar_read}
      end

      def in_block
        return if @xs.empty?
        [1].each { reset! }
        #{ivar_read}
      end

      def in_condition
        return if @xs.empty?
        puts 2 if reset!
        #{ivar_read}
      end
    RUBY
  end

  it "drops the fact of a local handed to `yield`" do
    expect_no_stale_size(<<~RUBY, reads: 3)
      def yielded
        #{guard}
        yield xs
        #{read}
      end

      def yielded_keyword
        #{guard}
        yield(1, target: xs)
        #{read}
      end

      def yielded_value
        #{guard}
        answer = yield(xs)
        puts answer
        #{read}
      end
    RUBY
  end

  it "drops the fact of a literal Array's element a symbol block mutates" do
    expect_no_stale_size(<<~RUBY, reads: 1)
      def symbol_block
        #{guard}
        [xs].each(&:clear)
        #{read}
      end
    RUBY
  end

  it "drops the fact of a receiver mutated through its Method object" do
    expect_no_stale_size(<<~RUBY, reads: 3)
      def bound
        #{guard}
        xs.method(:clear).call
        #{read}
      end

      def bound_paren
        #{guard}
        xs.public_method(:clear).()
        #{read}
      end

      def bound_computed(name)
        #{guard}
        xs.method(name).call
        #{read}
      end
    RUBY
  end

  it "drops the fact of a receiver whose `instance_eval` / `instance_exec` block mutates it" do
    expect_no_stale_size(<<~RUBY, reads: 3)
      def evaled
        #{guard}
        xs.instance_eval { clear }
        #{read}
      end

      def execed
        #{guard}
        xs.instance_exec { self.pop }
        #{read}
      end

      def evaled_opaque(blk)
        #{guard}
        xs.instance_eval(&blk)
        #{read}
      end
    RUBY
  end

  it "drops the fact of the receiver of a `send` whose name is computed" do
    expect_no_stale_size(<<~RUBY, reads: 3)
      def sent(name)
        #{guard}
        xs.send(name)
        #{read}
      end

      def public_sent(name)
        #{guard}
        xs.public_send(name)
        #{read}
      end

      def under_sent(name)
        #{guard}
        xs.__send__(name)
        #{read}
      end
    RUBY
  end

  it "drops the shape of a local whose alias, and of an instance variable that, receives a computed `send`" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[Integer]]", "Array[Dynamic[String]]"])
      class Sender
        def initialize
          @xs = gets.to_s.chars
        end

        def aliased(name)
          xs = [1, 2]
          ys = xs
          ys.send(name)
          Rigor.dump_type(xs)
        end

        def ivar(name)
          return if @xs.empty?
          @xs.send(name)
          Rigor.dump_type(@xs)
        end
      end
    RUBY
  end

  # The seven shapes the review of #3339 listed, and the closure made before the guard, in one file: `pop` on a
  # non-empty array answers `T` only where none of them leaves `positive-int` behind.
  # The instance-variable row is the spelling the change covers: a class whose `initialize` assigns `@xs`. In a
  # top-level method, where `self` is `main`, the same lines still read `positive-int`.
  def shapes_waited_on
    <<~RUBY
      class Holder
        def initialize
          @xs = gets.to_s.chars
        end

        def reset! = @xs.clear

        def ivar_reset
          return if @xs.empty?
          reset!
          Rigor.dump_type(@xs.size)
        end
      end

      def closure_before
        xs = gets.to_s.chars
        clear_it = -> { xs.clear }
        return if xs.empty?
        clear_it.call
        Rigor.dump_type(xs.size)
      end

      def closure_after
        #{guard}
        clear_it = -> { xs.clear }
        clear_it.call
        Rigor.dump_type(xs.size)
      end

      def loop_back_edge
        #{guard}
        loop do
          Rigor.dump_type(xs.size)
          xs.pop
        end
      end

      def rescue_entry
        #{guard}
        begin
          xs.clear
          raise "x"
        rescue StandardError
          Rigor.dump_type(xs.size)
        end
      end

      def yielded
        #{guard}
        yield xs
        Rigor.dump_type(xs.size)
      end

      def symbol_block
        #{guard}
        [xs].each(&:clear)
        Rigor.dump_type(xs.size)
      end
    RUBY
  end

  it "leaves no `positive-int` size in the file of shapes #3339 waits on" do
    expect(dumped_types(shapes_waited_on)).to eq(Array.new(7, "non-negative-int"))
  end

  describe "what stays as it was" do
    it "keeps the guard's fact where nothing touches the collection" do
      expect(dumped_types(<<~RUBY)).to eq(%w[positive-int positive-int])
        def untouched
          #{guard}
          Rigor.dump_type(xs.size)
        end

        def other_yielded(ys)
          #{guard}
          yield ys
          xs.send(:size)
          xs.instance_eval { size }
          xs.method(:size).call
          [xs].each(&:size)
          Rigor.dump_type(xs.size)
        end
      RUBY
    end

    it "keeps the guard's fact past a lambda, a `loop` and a `begin` body that only read the collection" do
      expect(dumped_types(<<~RUBY)).to eq(%w[positive-int positive-int positive-int])
        def read_in_lambda
          #{guard}
          show = -> { xs.size }
          show.call
          Rigor.dump_type(xs.size)
        end

        def read_in_loop
          #{guard}
          loop do
            Rigor.dump_type(xs.size)
            break
          end
        end

        def read_in_rescue
          #{guard}
          begin
            puts xs.first
          rescue StandardError
            Rigor.dump_type(xs.size)
          end
        end
      RUBY
    end

    it "keeps an instance variable's fact past a method on `self` that only reads it or appends to it" do
      expect(dumped_types(holder(<<~RUBY))).to eq(%w[positive-int positive-int])
        def read
          return if @xs.empty?
          count
          Rigor.dump_type(@xs.size)
        end

        def grow
          return if @xs.empty?
          add("a")
          Rigor.dump_type(@xs.size)
        end
      RUBY
    end

    it "keeps an instance variable's nil-freeness past a method on `self` that only mutates it in place" do
      rules = diagnostics(<<~RUBY).map(&:qualified_rule)
        class Buffer
          def initialize(flag)
            @xs = flag ? gets.to_s.chars : nil
          end

          def add(x) = @xs << x

          def fill
            return if @xs.nil?
            add("a")
            @xs.size
          end
        end
      RUBY
      expect(rules).not_to include("call.possible-nil-receiver")
    end

    it "still drops the fact after a direct mutator, an alias and a helper call" do
      expect_no_stale_size(<<~RUBY, reads: 3)
        def helper(a) = a.clear

        def direct
          #{guard}
          xs.clear
          #{read}
        end

        def aliased
          #{guard}
          ys = xs
          ys.clear
          #{read}
        end

        def helped
          #{guard}
          helper(xs)
          #{read}
        end
      RUBY
    end

    it "still drops the fact after a block, `tap`, a literal `send` and a `while` back edge" do
      expect_no_stale_size(<<~RUBY, reads: 4)
        def each_block
          #{guard}
          [1].each { xs.clear }
          #{read}
        end

        def tapped
          #{guard}
          xs.tap { |a| a.clear }
          #{read}
        end

        def literal_send
          #{guard}
          xs.send(:clear)
          #{read}
        end

        def while_loop
          #{guard}
          while true
            Rigor.dump_type(xs.size)
            break if xs.size == 0
            xs.pop
          end
        end
      RUBY
    end
  end
end
