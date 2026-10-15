# frozen_string_literal: true

# Two spellings of "the author already said what this does", over bodies that prove nothing (Floats: a declared `untyped` still declines an Integer literal, #1489).
module Annotated
  class Declared
    def store
      2.0
    end

    # @rbs %a{rigor:v1:effect io.db}
    def persist
      3
    end

    def typoed
      4.0
    end
  end
end
