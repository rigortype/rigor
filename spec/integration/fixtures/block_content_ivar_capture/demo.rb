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
end
