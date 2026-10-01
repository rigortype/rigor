require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1446 — a class guard disjoint from the receiver's `Nominal` reads the receiver as `bot`, but the value that
# passes the guard is of the guarded class, and a call on the receiver dispatches on that class. So calling a core
# method of the guarded `StringIO` keeps the narrowing: `@io.rewind; @io.string` stays quiet as `@io.string` does.
# Ruby 4.0.5 runs each quiet line without error under a `StringIO`. The call's arguments and literal block are still
# read, and a call on a guarded `Proc`, or on what a guarded `Array` yields, may run project code.
class Holder
  def initialize
    @io = STDOUT
    @lines = []
  end

  def reset = (@io = STDOUT)

  def rewound
    return unless @io.is_a?(StringIO)

    @io.rewind
    @io.string # QUIET-1446
  end

  def after_each_line
    return unless @io.is_a?(StringIO)

    @io.each_line { |line| @lines << line.chomp }
    @io.string # QUIET-1446
  end

  def rewound_in_case = (case @io when StringIO then @io.rewind; @io.string end) # QUIET-1446

  # Controls: a block or an argument of that call may still rebind the variable.
  def reset_in_block
    return unless @io.is_a?(StringIO)

    @io.each_line { reset }
    @io.string # FIRES-1446 call.undefined-method
  end

  def reset_in_argument
    return unless @io.is_a?(StringIO)

    @io.write(reset)
    @io.string # FIRES-1446 call.undefined-method
  end
end

# Controls: the guarded class runs project code. `@cb.call` runs whatever the `Proc` holds, and `item.poke` may be
# `Poker#poke`, which resets the holder's `@io`.
class Poker
  def initialize(holder) = (@holder = holder)
  def poke = @holder.reset
end

class Dispatcher
  def initialize
    @io = STDOUT
    @cb = :x
    @items = {}
  end

  def reset = (@io = STDOUT)

  def reset_by_guarded_proc
    return unless @io.is_a?(StringIO)
    return unless @cb.is_a?(Proc)

    @cb.call
    @io.string # FIRES-1446 call.undefined-method
  end

  def reset_by_what_a_guarded_array_yields
    return unless @io.is_a?(StringIO)
    return unless @items.is_a?(Array)

    @items.each { |item| item.poke }
    @io.string # FIRES-1446 call.undefined-method
  end
end

# The same holds for a constant receiver (#1429).
def rewound_constant
  return unless STDOUT.is_a?(StringIO)

  STDOUT.rewind
  STDOUT.string # QUIET-1446
end

# Control: a receiver the guard does not narrow to `bot` keeps the rule for calls on it. `@task.is_a?(Job)` reads
# `@task` as `Dynamic[top]` (a project subclass is not placed below `Task` here), an unresolved callee may rebind
# `@task`, and `@task` then reads the union of the binding the guard narrowed and the narrowed one.
class Task
  def run = nil
end

class Job < Task
  def detail = "d"
end

class Runner
  def initialize
    @task = Task.new
  end

  def run_job
    return unless @task.is_a?(Job)

    @task.run
    assert_type("Dynamic[top] | Task", @task)
  end

  def job_detail = (@task.is_a?(Job) ? @task.detail : nil) # QUIET-1446
end
