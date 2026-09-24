# frozen_string_literal: true

# #1039 — `Const.new` as a dispatch to `Const#initialize`. Every shape the rewrite has an answer for, and
# the two shapes it must leave alone: a `def self.new` override, and `Class.new`.
module ConstructorEdge
  # The plain case: a constructor that writes an ivar and calls a catalogued effectful method.
  class Recorder
    def initialize(path)
      @path = path
      File.write(path, "recording")
    end

    # `new` with no receiver inside a singleton body is the same edge as `Recorder.new`.
    def self.build(path)
      new(path)
    end
  end

  # No `#initialize` of its own; the one it inherits lives in `base.rb`.
  class Inherited < BaseWriter
  end

  # No `#initialize` anywhere in the project's ancestry, and a chain that closes inside the project — so
  # the constructor is `BasicObject#initialize`, whose footprint is ∅.
  class Bare
    def label
      "bare"
    end
  end

  # A project `def self.new` is the definition `Overridden.new` actually reaches, and it must win over the
  # `#initialize` beside it.
  class Overridden
    def self.new(*)
      puts("intercepted")
      nil
    end

    def initialize
      @data = File.read("/etc/hosts")
    end
  end

  class Client
    def record(path)
      Recorder.new(path)
    end

    def via_singleton(path)
      Recorder.build(path)
    end

    def inherit(path)
      Inherited.new(path)
    end

    def bare
      Bare.new
    end

    def intercept
      Overridden.new
    end

    # `Class.new` builds an anonymous class; it is not a constructor call on a project class and must not
    # reach any project `#initialize`.
    def anonymous
      Class.new
    end
  end
end

# The edge is keyed on the receiver's TYPE, so these three carry the identical tuple as a literal
# `Spread.new` — and unlike it, they really do construct a subclass.
module ConstructorEdge
  class Spread
    def clone_like
      self.class.new
    end

    def via_local
      klass = self.class
      klass.new
    end

    def self.build
      new
    end
  end

  class SpreadSub < Spread
    def initialize
      File.write("/tmp/spread", "x")
    end
  end

  # An ancestry the scanner cannot read: the superclass is an expression, not a constant path.
  class Generated < Struct.new(:a)
    def run
      "generated"
    end
  end

  # The constructor is another method's body, and the scanner models no aliases.
  class Aliased
    def setup
      File.write("/tmp/aliased", "x")
    end
    alias initialize setup
  end

  class Spreader
    # A written constant cannot reach `SpreadSub#initialize`.
    def literal
      Spread.new
    end

    def generated
      Generated.new(1)
    end

    def aliased
      Aliased.new
    end
  end
end

# A class built at load time and assigned to a constant, then reopened. The reopening is all the scan
# would otherwise see: project-known, no `<`, and a constructor the `Class.new` call already supplied.
module ConstructorEdge
  class RealSub < BaseWriter
  end

  Anon = Class.new(RealSub)

  class Anon
    def more
      "more"
    end
  end

  Point = Struct.new(:x)

  class Point
    def label
      "point"
    end
  end

  # An aliased constructor on a SUBCLASS, which only the downward half of the question finds. Its own
  # hierarchy, so the plain closed-world join above stays testable. The alias is written with string
  # arguments, which is the same declaration as the symbol one.
  class Widening
    def clone_like
      self.class.new
    end
  end

  class AliasedChild < Widening
    def setup
      File.write("/tmp/child", "x")
    end
    alias_method "initialize", "setup"
  end

  class Reopener
    def anon
      Anon.new("/tmp/anon")
    end

    def point
      Point.new(1)
    end

  end
end

module ConstructorEdge
  class Sticky < BaseWriter
    def more
      "more"
    end
  end

  # `self.class.new` on a base whose only load-time-built subclass has an unreadable constructor.
  class Widened
    def dup2
      self.class.new
    end
  end

  Grown = Class.new(Widened) do
    def initialize
      File.write("/tmp/grown", "x")
    end
  end

  class Reopener
    def sticky
      Sticky.new("/tmp/sticky")
    end
  end
end

# `include` inside `class << self` mixes the module into the singleton class, as `extend` does, so its
# `initialize` becomes a private class method that `new` never calls: `EigenSetup.new` runs
# `BasicObject#initialize` and writes nothing.
module ConstructorEdge
  module Setup
    def initialize
      File.write("/tmp/setup", "x")
    end
  end

  class EigenSetup
    class << self
      include Setup
    end

    def label
      "eigen"
    end
  end

  class EigenClient
    def build
      EigenSetup.new
    end
  end
end
