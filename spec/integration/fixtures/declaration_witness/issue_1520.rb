# frozen_string_literal: true

# https://github.com/rigortype/rigor/issues/1520 — a header inside class << self opens a class on the singleton
# class. Inside `class ::E` Ruby's nesting is [E, #<Class:C>::D, #<Class:C>, C], so `Bar` is the top-level Bar;
# Rigor's census scope pushes the header as C::D and types @@ad as C::D::Bar. The last line assigns @@ad so the
# witness can read the value Ruby holds.

class Bar
end

class C
  class D
    class Bar
    end
  end

  class << self
    class D
      class ::E
        def ad = (@@ad = Bar.new)
      end
    end
  end
end

E.new.ad
