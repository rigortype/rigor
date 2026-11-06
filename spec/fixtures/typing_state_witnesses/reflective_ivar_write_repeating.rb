# ADR-129 G1' witness for :reflective_ivar_write_repeating. A reflective write in a `for` body repeats, which the
# census reads as a widening.
class Probe
  def run
    for name in %w[a b]
      instance_variable_set("@#{name}", 1)
    end
    @a
  end
end
Probe.new.run
