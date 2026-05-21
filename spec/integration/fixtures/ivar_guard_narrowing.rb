require "rigor/testing"
include Rigor::Testing

# Redmine 6.x regression-sweep repro. `app/models/issue.rb`
# surfaced 6 false-positive `call.undefined-method` diagnostics,
# every one a `@current_journal.METHOD` call inside an
# `if @current_journal` guard: Rigor narrowed a truthy guard on
# a *local* variable but not on an *instance* variable, so the
# ivar kept its `Journal | nil` type inside the guarded branch
# and each method call on it reported `... for nil`.
#
# The three guard shapes the sweep + the Mastodon cluster-4 G2
# note flag: `if @ivar`, `@ivar && @ivar.method`, and
# `unless @ivar.nil?`. All three must narrow the ivar to its
# non-nil fragment inside the guarded branch.
class Journal
  def user
    "u"
  end
end

class Issue
  # `if @ivar` — truthy guard narrows the ivar to non-nil.
  def guard_if
    @current_journal = rand < 0.5 ? Journal.new : nil
    if @current_journal
      assert_type("Journal", @current_journal)
      @current_journal.user
    end
  end

  # `@ivar && @ivar.method` — short-circuit narrows the right arm.
  def guard_and
    @current_journal = rand < 0.5 ? Journal.new : nil
    @current_journal && @current_journal.user
  end

  # `unless @ivar.nil?` — `nil?`-predicate guard, reversed edges.
  def guard_unless_nil
    @current_journal = rand < 0.5 ? Journal.new : nil
    unless @current_journal.nil?
      assert_type("Journal", @current_journal)
      @current_journal.user
    end
  end
end
