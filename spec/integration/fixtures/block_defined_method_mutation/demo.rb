require "rigor/testing"
include Rigor::Testing

# The content seams leave a `def` body the block defines out, because
# it runs only when called. The block may call it, though, and then the
# method's in-place mutation of an instance variable, class variable or
# global runs during the block (issue #3163). No call is followed: such
# a variable floors to its bare collection whenever the block defines
# the method. Every comparison below is TRUE at runtime unless it is
# marked, and nothing but the marked lines may report.

class BlockDefinedMethodMutation
  # --- Defined and called in the block. ---
  def ivar_called
    @iv = [0]
    [1].each do
      def ivar_helper
        @iv << 1
      end
      ivar_helper
    end
    puts "one" if @iv.last == 1
  end

  # Called by a name the analyzer does not read. The `[0]` member is the
  # reset a call on `self` makes, joined with the floor.
  def ivar_sent
    @sent = [0]
    [1].each do
      def ivar_sent_helper
        @sent << 1
      end
      send(:ivar_sent_helper)
    end
    assert_type("Array[Dynamic[top]] | [0]", @sent)
    puts "one" if @sent.last == 1
  end

  def cvar_called
    @@cv = [0]
    [1].each do
      def cvar_helper
        @@cv << 1
      end
      cvar_helper
    end
    assert_type("Array[Dynamic[top]]", @@cv)
    puts "one" if @@cv.last == 1
  end

  # An index write and a String append floor the same way.
  def cvar_hash_stored
    @@seen = { a: 0 }
    [1].each do
      def cvar_store_helper
        @@seen[:b] = 1
      end
      cvar_store_helper
    end
    assert_type("Hash[Dynamic[top], Dynamic[top]]", @@seen)
    puts "one" if @@seen[:b] == 1
  end

  def cvar_string_appended
    @@text = +"a"
    [1].each do
      def cvar_text_helper
        @@text << "b"
      end
      cvar_text_helper
    end
    assert_type("String", @@text)
    puts "ab" if @@text == "ab"
  end

  # --- A nested block defines the method. ---
  def cvar_nested_block
    @@nb = [0]
    [1].each do
      [2].each do
        def cvar_nested_block_helper
          @@nb << 1
        end
      end
      cvar_nested_block_helper
    end
    assert_type("Array[Dynamic[top]]", @@nb)
    puts "one" if @@nb.last == 1
  end

  # --- The mutation sits in a block inside the method. ---
  def cvar_block_in_method
    @@bm = [0]
    [1].each do
      def cvar_block_in_method_helper
        [5].each { |x| @@bm << x }
      end
      cvar_block_in_method_helper
    end
    assert_type("Array[Dynamic[top]]", @@bm)
    puts "five" if @@bm.last == 5
  end

  # --- A singleton method on `self` mutates the same object's instance
  # variable. ---
  def ivar_singleton_def
    @sd = [0]
    [1].each do
      def self.ivar_singleton_helper
        @sd << 1
      end
      send(:ivar_singleton_helper)
    end
    assert_type("Array[Dynamic[top]] | [0]", @sd)
    puts "one" if @sd.last == 1
  end

  # --- The block sits in a call's argument or receiver. ---
  def cvar_argument_block
    @@arg = [0]
    puts([1].each do
      def cvar_argument_helper
        @@arg << 1
      end
      cvar_argument_helper
    end)
    assert_type("Array[Dynamic[top]]", @@arg)
    puts "one" if @@arg.last == 1
  end

  def cvar_receiver_block
    @@rcv = { a: 0 }
    [1].each do
      def cvar_receiver_helper
        @@rcv[:b] ||= 1
      end
      cvar_receiver_helper
    end.size
    assert_type("Hash[Dynamic[top], Dynamic[top]]", @@rcv)
    puts "one" if @@rcv[:b] == 1
  end

  # --- The block itself first binds the variable, so the call site has
  # no binding for it. ---
  def ivar_seeded_in_block
    [1].each do
      @sb = [0]
      def ivar_seeded_helper
        @sb << 1
      end
      ivar_seeded_helper
    end
    assert_type("Array[Dynamic[top]] | [0]", @sb)
    puts "one" if @sb.last == 1
  end

  # Guard, not a fix: a class variable the block first binds is not
  # written back to the continuation, so it never read `[0]` there. The
  # global row at the end of the file is the same.
  def cvar_seeded_in_block
    [1].each do
      @@sb = [0]
      def cvar_seeded_helper
        @@sb << 1
      end
      cvar_seeded_helper
    end
    assert_type("Dynamic[Array[Dynamic[top]]]", @@sb)
    puts "one" if @@sb.last == 1
  end

  # --- A mutator the content joins read no evidence from (`merge!`,
  # `map!`) floors too: the floor needs none. ---
  def cvar_merged
    @@mg = { a: 1 }
    [1].each do
      def cvar_merge_helper
        @@mg.merge!(b: 2)
      end
      cvar_merge_helper
    end
    assert_type("Hash[Dynamic[top], Dynamic[top]]", @@mg)
    puts "two" if @@mg[:b] == 2
  end

  def cvar_mapped
    @@mp = [1]
    [1].each do
      def cvar_map_helper
        @@mp.map!(&:to_s)
      end
      cvar_map_helper
    end
    assert_type("Array[Dynamic[top]]", @@mp)
    puts "one" if @@mp.first == "1"
  end

  def cvar_mapped_escaping
    @@me = [1]
    definer = lambda do
      def cvar_map_escaping_helper
        @@me.map!(&:to_s)
      end
      cvar_map_escaping_helper
    end
    assert_type("Array[Dynamic[top]]", @@me)
    definer.call
    puts "one" if @@me.first == "1"
  end

  # --- A nil-able seed keeps its `nil` on the floor. ---
  def cvar_kept_nil(flag)
    @@kn = flag ? [1] : nil
    [1].each do
      def cvar_kept_nil_helper
        @@kn&.push(2)
      end
      cvar_kept_nil_helper
    end
    assert_type("Array[Dynamic[top]]?", @@kn)
  end

  # --- An escaping block and a lambda floor the same names. ---
  def cvar_escaping(button)
    @@esc = [0]
    button.on_click do
      def cvar_escaping_helper
        @@esc << 1
      end
      cvar_escaping_helper
    end
    assert_type("Array[Dynamic[top]]", @@esc)
    button.click
    puts "one" if @@esc.last == 1
  end

  def cvar_lambda
    @@lam = { a: 0 }
    definer = lambda do
      def cvar_lambda_helper
        @@lam[:b] = 1
      end
      cvar_lambda_helper
    end
    assert_type("Hash[Dynamic[top], Dynamic[top]]", @@lam)
    definer.call
    puts "one" if @@lam[:b] == 1
  end

  # --- Known limit: no call is followed, so a method the block defines
  # and nothing calls floors too, and so does one called only after the
  # read. Ruby holds `[0]` at both reads. ---
  def cvar_never_called
    @@nc = [0]
    [1].each do
      def cvar_never_called_helper
        @@nc << 1
      end
    end
    assert_type("Array[Dynamic[top]]", @@nc)
  end

  def cvar_called_after_read
    @@late = [0]
    [1].each do
      def cvar_late_helper
        @@late << 1
      end
    end
    assert_type("Array[Dynamic[top]]", @@late)
    cvar_late_helper
  end

  # Known limit: a plain `def` counts wherever it is written, so one in
  # a `Class.new` block, whose instance variables are the new class's
  # instances', floors this object's too. Ruby holds `[0]`.
  def ivar_class_new_block
    @cn = [0]
    klass = Class.new do
      def m
        @cn << 1 if @cn
      end
    end
    assert_type("Array[Dynamic[top]]", @cn)
    klass
  end

  # --- Paired controls. ---

  # A method that only reads the class variable leaves it folding.
  def cvar_read_only
    @@ro = [0]
    [1].each do
      def cvar_read_only_helper
        @@ro.size
      end
      cvar_read_only_helper
    end
    puts "never" if @@ro.last == 1 # GENUINE-FALSEY
  end

  # A method defined on another object mutates that object's instance
  # variable, not this one's.
  def ivar_other_receiver(other)
    @or = [0]
    [1].each do
      def other.ivar_other_helper
        @or << 1 if @or
      end
      other.ivar_other_helper
    end
    assert_type("Array[0]", @or)
  end

  # A method defined in a block that runs on another object mutates that
  # object's instance variable.
  def ivar_foreign_self_block
    @fsb = [0]
    String.instance_eval do
      def ivar_foreign_helper
        @fsb << 1 if @fsb
      end
    end
    assert_type("Array[0]", @fsb)
  end

  # A class body in the block has class variables of its own, and its
  # methods are that class's.
  @@cb = [0]
  [1].each do
    class ClassBodyMethod
      @@cb = [9]
      def m
        @@cb << 1
      end
    end
  end
  assert_type("[0]", @@cb)
end

# --- A global, defined and called in a top-level block. ---
$bdm_buf = []
[1].each do
  def bdm_global_helper
    $bdm_buf << 1
  end
  bdm_global_helper
end
assert_type("Array[Dynamic[top]]", $bdm_buf)
puts "one" if $bdm_buf.last == 1

# A method of a class the block opens is left out: the walks do not ask
# who calls it.
$bdm_cls = [0]
[1].each do
  class BdmGlobalClassBody
    def m
      $bdm_cls << 1
    end
  end
end
assert_type("[0]", $bdm_cls)

# --- Guard: a global the block itself first binds. ---
[1].each do
  $bdm_seeded = [0]
  def bdm_seeded_helper
    $bdm_seeded << 1
  end
  bdm_seeded_helper
end
assert_type("Array[Dynamic[top]]", $bdm_seeded)
puts "one" if $bdm_seeded.last == 1
