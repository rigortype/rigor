# A plain `def` in the receiver's own class.
class Plain
  def one(a) = a
end

Plain.new.one(1, 2)
