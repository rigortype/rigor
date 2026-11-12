require "rigor/testing"
include Rigor::Testing

# ADR-56's content seams — the slice-C join for a non-escaping block,
# the bare-collection floor for an escaping one, and the per-store
# overlay for a value the body rebinds — read a captured LOCAL only, so
# an instance variable the block mutates in place kept its pre-call
# contents (issues #1208, #1235). Every comparison below is TRUE at
# runtime unless it is marked, and nothing but the marked lines may
# report.

class IvarContentCapture
  # --- Non-escaping: an Array the block appends to. ---
  def appended
    @out = [0]
    [1, 2, 3].each { |x| @out << x }
    assert_type("Array[0 | 1 | 2 | 3]", @out)
    puts "three" if @out.last == 3
  end

  # --- Non-escaping: a Hash the block stores into. ---
  def stored
    @seen = { a: 0 }
    [:a, :b].each { |k| @seen[k] = 1 }
    assert_type("Hash[:a | :b | Symbol, 0 | 1]", @seen)
    puts "one" if @seen[:a] == 1
  end

  # --- Escaping: a callback the receiver keeps and runs later. ---
  def escaping(button)
    @opts = { format: "text" }
    button.on_click { @opts[:format] = "json" }
    button.click
    assert_type("Hash[Dynamic[top], Dynamic[top]]", @opts)
    puts "json" if @opts[:format] == "json"
  end

  # --- A store that reads an instance variable the body rebinds. ---
  def running_total
    @total = 0
    out = []
    [1, 2].each do |x|
      @total += x
      out << @total
    end
    assert_type("Array[Dynamic[top]]", out)
    puts "three" if out.last == 3
  end

  # --- Paired controls: the local spelling of each shape. ---
  def local_appended
    out = [0]
    [1, 2, 3].each { |x| out << x }
    assert_type("Array[0 | 1 | 2 | 3]", out)
  end

  def local_stored
    seen = { a: 0 }
    [:a, :b].each { |k| seen[k] = 1 }
    assert_type("Hash[:a | :b | Symbol, 0 | 1]", seen)
  end

  # --- Paired control: an instance variable the block only reads still
  # folds. ---
  def read_only
    @fixed = [0]
    [1, 2].each { |x| puts x if @fixed.size > x }
    puts "never" if @fixed.last == 1 # GENUINE-FALSEY
  end

  # --- Paired control: under `instance_eval` on a class object the
  # block's `@mine` is that class's, so this object's `@mine` keeps its
  # contents. A receiver that may be `self` (a parameter) is floored. ---
  def foreign_self
    @mine = [0]
    String.instance_eval { @mine << 1 if @mine }
    assert_type("Array[0]", @mine)
  end

  def maybe_self(other)
    @theirs = [0]
    other.instance_eval { @theirs << 1 }
    assert_type("Array[Dynamic[top]]", @theirs)
  end

  # --- A store that reads a joined instance variable moves with it: the
  # join must not type it at the pre-call contents. ---
  def self_read
    @grown = [0]
    [1, 2].each { |_x| @grown << @grown.size }
    puts "two" if @grown.last == 2
  end

  def cross_read
    @base = [0]
    lengths = []
    [1, 2].each do |x|
      @base << x
      lengths << @base.length
    end
    puts "three" if lengths.last == 3
  end

  def memo_read
    @fed = [0]
    sizes = [1, 2].each_with_object([]) do |x, m|
      @fed << x
      m << @fed.length
    end
    puts "three" if sizes.last == 3
  end

  # --- A nil-able instance variable keeps its pre-call binding on both
  # paths: the join and the floor would drop the `nil` (#1219, #1251). ---
  def guarded(flag)
    @maybe = flag ? [1] : nil
    [1].each { @maybe << 2 if @maybe }
    assert_type("Array[1]?", @maybe)
    y = @maybe.nil? ? 1 : 2
    puts "one" if y == 1
  end

  def guarded_escaping(button, flag)
    @later = flag ? [1] : nil
    button.on_click { @later&.push(2) }
    assert_type("Array[1]?", @later)
    y = @later.nil? ? 1 : 2
    puts "one" if y == 1
  end

  # --- A rewriter beside an append is re-applied to the join. ---
  def rewritten
    @rw = [1]
    [0].each do |_x|
      @rw.map!(&:to_s)
      @rw << "x"
    end
    assert_type("Array[Dynamic[top]]", @rw)
    puts "one" if @rw.first == "1"
  end

  # --- Paired controls: an instance variable of another object, under a
  # block nested in the seam's block or in a method the block defines,
  # keeps this object's binding. ---
  def nested_foreign
    @nf = [0]
    [1].each { String.instance_eval { @nf << 1 if @nf } }
    assert_type("Array[0]", @nf)
  end

  def nested_def
    @nd = [0]
    [1].each do
      def nested_helper
        @nd << 1
      end
    end
    assert_type("Array[0]", @nd)
  end


  # --- Paired control for #1235: a store reading an instance variable the
  # body does not write keeps its precise binding, and still folds. ---
  def unwritten_read
    @limit = 5
    @tally = 0
    caps = []
    [1, 2].each do |x|
      @tally += x
      caps << @limit
    end
    assert_type("Array[5]", caps)
    puts "never" if caps.last == 6 # GENUINE-FALSEY
  end
end

# --- An instance variable on its ADR-58 declaration seed is left alone:
# the seed already unions every write in the class, so the block's `1`
# does not join it. ---
class IvarContentSeeded
  def initialize
    @seeded = [0]
  end

  def seed_read
    [1].each { |x| @seeded << x }
    assert_type("Array[Dynamic[top]]", @seeded)
  end
end
