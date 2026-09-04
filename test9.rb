class A
  autoload :B, './missing.rb'
  C = 42
end
class D < A; end

p D.autoload?(:B) # Should be './missing.rb'
p D.const_defined?(:B) # Should be true

# If we reject autoloads:
if D.autoload?(:B)
  puts "Rejected B"
else
  D.const_get(:B)
end

if D.autoload?(:C)
  puts "Rejected C"
else
  p D.const_get(:C)
end
