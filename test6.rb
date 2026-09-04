class A
  B = 1
end
class C < A
end

p C.const_get("B", false)
