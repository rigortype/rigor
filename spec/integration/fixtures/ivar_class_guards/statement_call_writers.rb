require "rigor/testing"
include Rigor::Testing

# Issue #2039 — a statement self-call whose write set the #1596 proof cannot clear still leaves the reset unmarked
# when the callee's own body assigns the variable a value that may be `nil` (`DirectIvarWrites`). The proof declines
# here for a reason in the callee (a `yield`, a call on a parameter, an unknown self-call, a safe-navigation call on
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

  def notify_somebody = nil

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
