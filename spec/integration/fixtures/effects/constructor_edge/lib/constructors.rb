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
