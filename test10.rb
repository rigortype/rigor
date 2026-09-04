class A; B = 42; end
class C < A; end
p Object.const_get("C::B")
