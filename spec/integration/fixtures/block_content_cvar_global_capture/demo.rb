require "rigor/testing"
include Rigor::Testing

# ADR-56's content seams — the slice-C join for a non-escaping block,
# the bare-collection floor for an escaping one, and the per-store
# overlay for a value the body rebinds — took a local and an instance
# variable only, so a class variable or a global the block mutates in
# place kept its pre-call contents (issue #3096). Every comparison below
# is TRUE at runtime unless it is marked, and nothing but the marked
# lines may report.

class CvarGlobalContentCapture
  # --- Non-escaping: an Array the block appends to. ---
  def cvar_appended
    @@out = [0]
    [1, 2, 3].each { |x| @@out << x }
    assert_type("Array[0 | 1 | 2 | 3]", @@out)
    puts "three" if @@out.last == 3
  end

  def global_appended
    $cg_out = [0]
    [1, 2, 3].each { |x| $cg_out << x }
    assert_type("Array[0 | 1 | 2 | 3]", $cg_out)
    puts "three" if $cg_out.last == 3
  end

  # --- Non-escaping: a Hash the block stores into. ---
  def cvar_stored
    @@seen = { a: 0 }
    [:a, :b].each { |k| @@seen[k] = 1 }
    assert_type("Hash[:a | :b | Symbol, 0 | 1]", @@seen)
    puts "one" if @@seen[:a] == 1
  end

  def global_stored
    $cg_seen = { a: 0 }
    [:a, :b].each { |k| $cg_seen[k] = 1 }
    assert_type("Hash[:a | :b | Symbol, 0 | 1]", $cg_seen)
    puts "one" if $cg_seen[:a] == 1
  end

  # --- Escaping: a callback the receiver keeps and runs later. ---
  def cvar_escaping(button)
    @@opts = { format: "text" }
    button.on_click { @@opts[:format] = "json" }
    button.click
    puts "json" if @@opts[:format] == "json"
  end

  def global_escaping(button)
    $cg_buf = [0]
    button.on_click { $cg_buf << 1 }
    button.click
    puts "one" if $cg_buf.last == 1
  end

  # The escaping floor read right after the closure, before any condition
  # re-narrows the binding: each mismatches if the floor drops the `nil`
  # or leaves the pre-call contents.
  def cvar_kept_nil(button, flag)
    @@kn = flag ? [1] : nil
    button.on_click { @@kn&.push(2) }
    assert_type("Array[Dynamic[top]]?", @@kn)
  end

  def global_kept_nil(flag)
    $cg_kn = flag ? { a: 1 } : nil
    _cb = -> { $cg_kn[:a] = 2 if $cg_kn }
    assert_type("Hash[Dynamic[top], Dynamic[top]]?", $cg_kn)
  end

  # --- A store that reads a class variable or global the body rebinds. ---
  def cvar_running_total
    @@total = 0
    out = []
    [1, 2].each do |x|
      @@total += x
      out << @@total
    end
    assert_type("Array[Dynamic[top]]", out)
    puts "three" if out.last == 3
  end

  def global_running_total
    $cg_total = 0
    out = []
    [1, 2].each do |x|
      $cg_total += x
      out << $cg_total
    end
    assert_type("Array[Dynamic[top]]", out)
    puts "three" if out.last == 3
  end

  # --- A store that reads a joined class variable or global moves with
  # it. ---
  def cvar_self_read
    @@grown = [0]
    [1, 2].each { |_x| @@grown << @@grown.size }
    puts "two" if @@grown.last == 2
  end

  def global_self_read
    $cg_grown = [0]
    [1, 2].each { |_x| $cg_grown << $cg_grown.size }
    puts "two" if $cg_grown.last == 2
  end

  # --- A block that runs on another object still mutates this class's
  # class variable (Ruby resolves it lexically) and the one global. ---
  def cvar_foreign_self
    @@fs = [0]
    String.instance_eval { @@fs << 1 }
    puts "one" if @@fs.last == 1
  end

  def global_foreign_self
    $cg_fs = [0]
    String.instance_eval { $cg_fs << 1 }
    puts "one" if $cg_fs.last == 1
  end

  def cvar_nested_foreign
    @@nf = [0]
    [1].each { String.instance_eval { @@nf << 1 } }
    puts "one" if @@nf.last == 1
  end

  # --- A lookup mutator (`default=`) beside a store answers a missing
  # key with the default, not the seed's known values. ---
  def cvar_lookup_seed
    @@b = { a: 1 }
    [1].each do
      @@b.default = 0
      @@b[:c] = 2
    end
    puts "a" if @@b[:zz] == 0
  end

  def global_lookup_seed
    $cg_b = { a: 1 }
    [1].each do
      $cg_b.default = 0
      $cg_b[:c] = 2
    end
    puts "a" if $cg_b[:zz] == 0
  end

  # --- A rewriter beside an append is re-applied to the join. ---
  def cvar_rewritten
    @@rw = [1]
    [0].each do |_x|
      @@rw.map!(&:to_s)
      @@rw << "x"
    end
    assert_type("Array[Dynamic[top]]", @@rw)
    puts "one" if @@rw.first == "1"
  end

  # --- `class << self` keeps the enclosing class's class variables, and
  # its body runs at once. ---
  def cvar_singleton_body
    @@sc = [0]
    [1].each do
      class << self
        @@sc << 1
      end
    end
    puts "one" if @@sc.last == 1
  end

  # --- Paired controls. ---

  # A class variable the block only reads still folds.
  def cvar_read_only
    @@fixed = [0]
    [1, 2].each { |x| puts x if @@fixed.size > x }
    puts "never" if @@fixed.last == 1 # GENUINE-FALSEY
  end

  # A nil-able seed keeps its pre-call binding on the non-escaping join,
  # which would drop the `nil` (#1219).
  def cvar_guarded(flag)
    @@maybe = flag ? [1] : nil
    [1].each { @@maybe << 2 if @@maybe }
    assert_type("[1]?", @@maybe)
  end

  # Guard, not a fix: a global Ruby's own signatures declare is left to
  # the interpreter's handling, so `$;` keeps its pre-call contents
  # although the runtime appends (#3126).
  def special_global
    $; = +","
    [1].each { $; << "y" }
    assert_type('","', $;)
  end

  # A `def` the block defines runs only when called.
  def cvar_nested_def
    @@nd = [0]
    [1].each do
      def cvar_nested_helper
        @@nd << 1
      end
    end
    assert_type("[0]", @@nd)
  end

  def global_nested_def
    $cg_nd = [0]
    [1].each do
      def global_nested_helper
        $cg_nd << 1
      end
    end
    assert_type("[0]", $cg_nd)
  end

  # A class body in the block has class variables of its own.
  @@ck = [0]
  [1].each do
    class CvarClassBody
      @@ck = [9]
      @@ck << 1
    end
  end
  assert_type("[0]", @@ck)
end

# A module body in the block runs at once, and reads the one global.
$cg_tm = [0]
[1].each do
  module GlobalModuleBody
    $cg_tm << 1
  end
end
puts "one" if $cg_tm.last == 1
