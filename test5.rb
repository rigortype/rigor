class A
  autoload :B, './b.rb'
end
class C < A
end

p C.autoload?(:B)
