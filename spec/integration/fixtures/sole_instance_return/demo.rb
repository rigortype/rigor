# The only instance of `FalseClass` is `false`, so a body typed `FalseClass` (`Array.new(n, false)`
# binds `[T] (Integer, T)` to the nominal) satisfies a declared `bool`. Read apart, each `ok_*`
# method drew `def.return-type-mismatch` on correct code; `genuinely_wrong` is the live-rule control.
class Flags
  def ok_array(n)
    Array.new(n, false)
  end

  def ok_element(n)
    Array.new(n, false)[0]
  end

  def ok_nil_class(n)
    Array.new(n, nil).first
  end

  def genuinely_wrong(n) # GENUINE-MISMATCH
    Array.new(n, "no")
  end
end
