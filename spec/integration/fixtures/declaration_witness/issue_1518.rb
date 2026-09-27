# frozen_string_literal: true

# https://github.com/rigortype/rigor/issues/1518 — `class self::Opaque` inside a class_eval block on a receiver
# that is not a constant. Ruby defines `#<Class:0x…>::Opaque`, which no constant path names, so Rigor should
# decline the declaration. Today building the discovery index raises "anonymous class has no name". The Foo
# half is the issue's control: a constant receiver still opens Foo::Bar.

module Registry
  REGISTRY = [Class.new].freeze

  REGISTRY.first.class_eval do
    class self::Opaque
    end
  end
end

class Foo
end

Foo.class_eval do
  class self::Bar
  end
end
