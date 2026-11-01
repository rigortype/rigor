require "rigor/testing"
include Rigor::Testing

# Issue #2039 — a statement self-call whose write set the #1596 proof cannot clear still leaves the reset unmarked
# when the callee's own body assigns the variable a value that may be `nil` (`DirectIvarWrites`). The proof declines
# here for a reason in the callee (a `yield`, a call on a parameter, a self-call to a `define_method` method, a safe-navigation call on
# an ivar, a call on a project constant) or in the class (`include Comparable`, `method_missing`), and each read
# still reports. Under Ruby 4.0.5 every `probe_*` raises NoMethodError on `nil`.
class CalleeWriters
  def initialize
    @tag = "t"
    @logger = nil
  end

  def r_yield
    @tag = nil
    yield if block_given?
  end

  def r_param(x)
    @tag = nil
    x.to_s
  end

  def r_unknown_self
    @tag = nil
    notify_somebody
  end

  define_method(:notify_somebody) { nil }

  def r_logger
    @tag = nil
    @logger&.info("x")
  end

  def r_project_const
    @tag = nil
    CalleeWriters.name
  end

  def r_transitive = r_yield

  def probe_yield
    return unless @tag

    r_yield
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end

  def probe_param
    return unless @tag

    r_param(1)
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end

  def probe_unknown_self
    return unless @tag

    r_unknown_self
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end

  def probe_logger
    return unless @tag

    r_logger
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end

  def probe_project_const
    return unless @tag

    r_project_const
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end

  def probe_transitive
    return unless @tag

    r_transitive
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end
end

class ComparableWriter
  include Comparable

  def initialize = @tag = "t"
  def clear = @tag = nil
  def <=>(other) = 0

  def probe_clear
    return unless @tag

    clear
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end
end

class MissingWriter
  def initialize = @tag = "t"
  def clear = @tag = nil
  def method_missing(name, *) = super
  def respond_to_missing?(*) = true

  def probe_clear
    return unless @tag

    clear
    t = @tag
    t.upcase # FIRES-1446 call.possible-nil-receiver
  end
end

# Issue #2482 — an `||` / `&&` that can answer `nil`, a multiple assignment of a single literal (Ruby binds every
# target after the first to `nil`), a nested target and a chained safe-navigation call are `nil` writes too. The
# `yield` makes the proof decline, and `r_return` may leave before its later write. Under Ruby 4.0.5 every
# `probe_*` raises NoMethodError on `nil`.
class ShapeWriters
  def initialize
    @tag = "t"
    @items = []
    @peer = nil
  end

  def r_or = (@tag = @items.first || nil; yield if block_given?)
  def r_and = (@tag = @items.empty? && nil; yield if block_given?)
  def r_single = (@a, @tag = 1; yield if block_given?)
  def r_nested = ((@a, @tag), @b = [1, nil], 2; yield if block_given?)
  def r_chain = (@tag = @peer&.tag&.upcase; yield if block_given?)
  def r_return = (@tag = nil; return if @items.empty?; @tag = "x"; yield if block_given?)

  def probe_or; return unless @tag; r_or; t = @tag; t.upcase; end # FIRES-1446 call.possible-nil-receiver
  def probe_and; return unless @tag; r_and; t = @tag; t.upcase; end # FIRES-1446 call.possible-nil-receiver
  def probe_single; return unless @tag; r_single; t = @tag; t.upcase; end # FIRES-1446 call.possible-nil-receiver
  def probe_nested; return unless @tag; r_nested; t = @tag; t.upcase; end # FIRES-1446 call.possible-nil-receiver
  def probe_chain; return unless @tag; r_chain; t = @tag; t.upcase; end # FIRES-1446 call.possible-nil-receiver
  def probe_return; return unless @tag; r_return; t = @tag; t.upcase; end # FIRES-1446 call.possible-nil-receiver
end
