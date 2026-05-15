require "rigor/testing"
include Rigor::Testing

# `is_a?(C)` MUST resolve `C` through the lexical-nesting chain
# (mirroring Ruby's `Module.nesting`-driven constant lookup), so
# a name shadowed by the enclosing class wins over a same-name
# top-level constant. The motivating case: rigor's own
# `Rigor::Type::Singleton` clashes with stdlib's `Singleton`
# mixin module — inside the class's instance methods,
# `is_a?(Singleton)` MUST narrow to `Rigor::Type::Singleton`,
# not to the unrelated `::Singleton`.
module Foo
  class Inner
    def each_known_class_name
      "inner"
    end
  end

  class Outer
    def call(other)
      # `Inner` here resolves to `Foo::Inner` per lexical scope.
      # The narrowing should let us call `Inner`-only methods
      # without a `call.undefined-method` diagnostic.
      if other.is_a?(Inner)
        assert_type('Foo::Inner', other)
      end
    end
  end
end
