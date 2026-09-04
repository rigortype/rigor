class A
  B = 1
end
class C < A
  B = A::B
end
p C.const_defined?("B", false)
