class A; class B; end; end
class C < A; end
p Object.const_get("C::B")
