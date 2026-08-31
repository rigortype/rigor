# Deprecations.warn minimal repro

class Dep
  class << self
    attr_accessor :warned

    Dep.warned = Set.new

    def warn(name, alternative)
      return if warned.include?(name)

      warned << name

      caller_location = caller_locations(2, 1).first
      Warning.warn("[DEPRECATION] #{name} is deprecated. Use #{alternative} instead. Called from #{caller_location}\n")
    end
  end
end

Dep.warn('a', 'b')
Dep.warned
