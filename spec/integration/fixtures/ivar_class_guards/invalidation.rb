require "stringio"

# Issue #1446 — a class guard's narrowing of an instance variable holds until code may run that rebinds the variable,
# and is then restored to the union of the binding the guard narrowed and the narrowed type (`IO` here). A method the
# project defines may rebind it, on `self` or on another object that holds `self`, and so may `instance_variable_set`,
# `send`, a lambda or a helper's block run later, and a write that a rescue clause or a loop's next pass reads after.
#
# Each reported read comes after code that may set `@io` back to `STDOUT`. Where that code does (`reset`, the
# reflective calls, the write), the read raises NoMethodError under Ruby 4.0.5 when `@io` held a `StringIO` at the
# guard; `with_retry` does not, and its block is reported because a helper's body is not read.
class Poker
  def initialize(holder) = (@holder = holder)
  def poke = @holder.reset
end

class Holder
  def initialize
    @io = STDOUT
    @poker = Poker.new(self)
  end

  def reset = (@io = STDOUT)
  def with_retry = yield

  def dropped_by_project_method_on_self
    return unless @io.is_a?(StringIO)

    reset
    @io.string # FIRES-1446 call.undefined-method
  end

  def dropped_by_project_method_on_another_receiver
    return unless @io.is_a?(StringIO)

    @poker.poke
    @io.string # FIRES-1446 call.undefined-method
  end

  def dropped_by_instance_variable_set
    return unless @io.is_a?(StringIO)

    holder = self
    holder.instance_variable_set(:@io, STDOUT)
    @io.string # FIRES-1446 call.undefined-method
  end

  def dropped_by_send
    return unless @io.is_a?(StringIO)

    holder = self
    holder.send(:reset)
    @io.string # FIRES-1446 call.undefined-method
  end

  def dropped_in_lambda
    return unless @io.is_a?(StringIO)

    -> { @io.string } # FIRES-1446 call.undefined-method
  end

  def dropped_in_helper_block
    return unless @io.is_a?(StringIO)

    with_retry { @io.string } # FIRES-1446 call.undefined-method
  end

  def dropped_by_write_before_rescue
    return unless @io.is_a?(StringIO)

    begin
      @io = STDOUT
      Integer("x")
    rescue ArgumentError
      @io.string # FIRES-1446 call.undefined-method
    end
  end

  def dropped_on_loop_next_pass
    return unless @io.is_a?(StringIO)

    i = 0
    while i < 2
      @io.string # FIRES-1446 call.undefined-method
      @io = STDOUT
      i += 1
    end
  end

  def dropped_in_case_when
    case @io
    when StringIO
      @poker.poke
      @io.string # FIRES-1446 call.undefined-method
    end
  end

  def dropped_by_write
    return unless @io.is_a?(StringIO)

    @io = STDOUT
    @io.string # FIRES-1446 call.undefined-method
  end
end
