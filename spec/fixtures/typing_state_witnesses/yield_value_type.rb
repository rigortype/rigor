# ADR-129 G1' witness for :yield_value_type. `yielder`'s body types `yield(1)` under the caller's block value, so the
# type of `r` is the block's, not Dynamic.
class Probe
  def yielder = yield(1)
  def run
    r = yielder { |x| x.to_s }
    r.upcase
  end
end
Probe.new.run
