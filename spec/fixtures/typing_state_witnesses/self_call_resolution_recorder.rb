# ADR-129 G1' witness for :self_call_resolution_recorder. An implicit-self call to an undefined method is recorded
# into the accumulator a recording installs while the file is typed.
class Probe
  def known = 1
  def run = [known, missing_call(2)]
end
Probe.new.run
