# ADR-129 G1' witness for :interface_erasure and :interface_dispatch_off (a sibling `interface_erasure.rbs` is the
# fixture's signature). `take`'s parameter is a plugin interface (`Rigor::Plugin::_WitnessReader`), which translates to
# a facet carrier unless the erasure baseline is installed, and `reader.read` dispatches through that carrier unless
# interface dispatch is off. A harness installs each switch around the run.
class Probe
  def take(reader) = reader.read.upcase
  def run = take(Object.new)
end
Probe.new.run
