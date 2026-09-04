class A
  autoload :B, './b.rb'
end
class C < A
end
p C.const_defined?("B", true)
p C.autoload?("B")
