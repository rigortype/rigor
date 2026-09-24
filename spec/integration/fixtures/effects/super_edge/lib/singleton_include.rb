# frozen_string_literal: true

# `include` is a call on `self`. Where `self` is the singleton class it mixes the module into the singleton
# class, which is what `extend` does: `Auditing#emit` becomes a class method, and an instance-side `super`
# skips it for the superclass's `emit`. `instance_eval` moves only the default definee, so an `include` in
# its block is still a call on the class and puts the module in the instance ancestry. `super_edge_spec.rb`
# evaluates this file, so each of these claims is also checked against Ruby.
module SuperEdge
  class EigenInclude < BaseWriter
    class << self
      include Auditing
    end

    def emit
      super
    end
  end

  class SingletonClassEvalInclude < BaseWriter
    singleton_class.class_eval do
      include Auditing
    end

    def emit
      super
    end
  end

  class EigenPrepend < BaseWriter
    class << self
      prepend Auditing
    end

    def emit
      super
    end
  end

  class InstanceEvalInclude < BaseWriter
    instance_eval do
      include Auditing
    end

    def emit(payload)
      super
    end
  end
end
