# frozen_string_literal: true

# https://github.com/rigortype/rigor/issues/1519 — a compact header whose leading segment names the enclosing
# class. Ruby finds `C` by constant lookup, so the class is C::Pathed; Rigor keys it C::C::Pathed.

class Base
end

class C
  class C::Pathed < Base
    def h = 1
  end
end
