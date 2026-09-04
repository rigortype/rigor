autoload :Missing, './missing.rb'
class A
  autoload :Missing2, './missing2.rb'
end
class C < A; end

p C.const_defined?("Missing2", true)
