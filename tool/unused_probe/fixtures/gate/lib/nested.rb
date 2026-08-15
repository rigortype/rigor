# frozen_string_literal: true

# Case 2: A::B::NestedOnly is referenced ONLY as the bare `NestedOnly` from inside A::B.
# The full name A::B::NestedOnly appears nowhere in the sources.
module A
  module B
    class NestedOnly
      def value = 1
    end

    class Caller
      def go
        NestedOnly.new.value
      end
    end
  end
end
