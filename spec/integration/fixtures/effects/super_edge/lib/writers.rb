# frozen_string_literal: true

# ADR-103 #446 — every shape a `super` takes, and the two answers it may have: the parent's summary when
# the project's own ancestry resolves it, and the `unresolved-super` taint when it does not. The ancestors
# themselves are in `base.rb`.
module SuperEdge
  # The issue's own five-line reproduction: a body that is nothing but `super`.
  class Bare < BaseWriter
    def emit
      super
    end
  end

  # `super()` — an explicit empty argument list, which is a different node from a bare `super` and a
  # different call from it too, the parent taking no arguments where this override does.
  class Parens < BaseWriter
    def emit(_mode = nil)
      super()
    end
  end

  # `super(args)`, reaching the module the class includes rather than its superclass.
  class Args
    include Auditing

    def emit(payload)
      super(payload.to_s)
    end
  end

  # The walk descends into a block literal by containment, so a `super` written inside one is the
  # enclosing method's.
  class InBlock < BaseWriter
    def emit
      [1].each { super() }
    end
  end

  class InRescue < BaseWriter
    def emit
      raise "boom"
    rescue StandardError
      super
    end
  end

  class Singleton < BaseWriter
    def self.build
      super
    end
  end

  # A `super` the project cannot resolve: `Object#to_s` is not an effect unit, and no envelope bounds it.
  class Unresolvable
    def to_s
      super
    end
  end

  # A caller of a delegating override reads the parent's effects, and a caller of an unresolvable one
  # reads the taint.
  class Client
    def run
      Bare.new.emit
    end

    def describe
      Unresolvable.new.to_s
    end
  end
end
