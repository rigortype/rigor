# frozen_string_literal: true

# rbs 4.1 renamed the type parameters of several core generics (ruby/rbs#2867): `Array[Elem]` became
# `Array[E]`, `Enumerator[Elem, Return]` became `Enumerator[E, R]`, `TSort[Node]` became `TSort[N]`.
#
# The gemspec supports `rbs >= 3.0, < 5.0` and CI's `rbs-compat` job runs the RBS-loading surface against
# both the 3.x and 4.x lines, so a spec asserting a DECLARED parameter name cannot hard-code either side of
# the rename. It reads the name from here instead.
module RbsCoreTypeParams
  RENAMED_IN = Gem::Version.new("4.1.0")

  # @return [Boolean] true on the rbs line that carries the renamed parameters.
  def self.renamed?
    Gem::Version.new(::RBS::VERSION) >= RENAMED_IN
  end

  # `Array`'s single element type parameter.
  # @return [Symbol] `:E` on rbs >= 4.1, `:Elem` before it.
  def self.array_element
    renamed? ? :E : :Elem
  end
end
