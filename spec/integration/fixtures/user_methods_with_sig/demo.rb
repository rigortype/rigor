require "rigor/testing"
include Rigor::Testing

# Same Ruby class as `user_methods.rb`, but this fixture
# layout includes a `sig/parity.rbs` declaring
# `is_odd` / `is_even` as `(Integer) -> bool`. The engine
# now dispatches the call through the RBS sig and the
# caller observes the `bool` return type instead of
# `Dynamic[top]`.
class Parity
  def is_odd(n)
    n.odd?
  end

  def is_even(n)
    n.even?
  end
end

p = Parity.new
assert_type("Parity", p)

a = p.is_odd(3)
b = p.is_even(4)

# `bool` in RBS is `true | false`; Type#describe(:short)
# renders it as `false | true`.
assert_type("false | true", a)
assert_type("false | true", b)
