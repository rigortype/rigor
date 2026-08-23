# frozen_string_literal: true

# Receivers whose type is a union rather than a single class (#455). Every one of these is an
# ordinary Ruby idiom, and before the union arm existed each contributed nothing to its summary
# while the row still read exhaustive.
module OptionalReceiver
  # The cross-method instance-variable read. ADR-58 contributes a declaration-sourced `nil` to any
  # ivar `initialize` does not write, so the receiver here is `File | nil` where the same expression
  # inside `open!` is a bare `File`.
  class IvarReader
    def open!
      @io = File.open("data.txt")
    end

    def read_it
      @io.read
    end
  end

  # The same shape a `find_by` produces, read through safe navigation.
  class SafeNavigator
    def read_it(flag)
      handle = flag ? File.open("data.txt") : nil
      handle&.read
    end
  end

  # An arm the typer could not name leaves the whole receiver a guess, exactly as a bare `Dynamic`
  # receiver does — so the site taints rather than reading as effect-free. Neither body below opens
  # anything itself: the only candidate label is the one the `.read` contributes.
  class UnknownArm
    def open!
      @io = File.open("data.txt")
    end

    def read_it(other)
      handle = @io || other
      handle.read
    end
  end

  # Arms that disagree project to nothing. Both of these perform `io.fs.read`, so the summary is a
  # miss rather than a lie — one call site carries one receiver class, and answering with either
  # arm would state an effect no single execution need perform.
  class DisagreeingArms
    def open!
      @io = File.open("data.txt")
      @dir = Dir.new(".")
    end

    def read_it(flag)
      handle = flag ? @io : @dir
      handle.read
    end
  end
end
