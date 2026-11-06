# ADR-129 G1' witness for :forwarded_call_arg_types. `forward(...)` expands to the caller's argument list, which
# `target`'s parameter types come from.
class Probe
  def target(first, second) = first.to_s + second.to_s
  def forward(...) = target(...)
  def run = forward(1, :two)
end
Probe.new.run
