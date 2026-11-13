require_relative "reopened_one"
class R1
  def set; @@x = "xx"; end
end
r = R1.new; r.set; puts r.len
