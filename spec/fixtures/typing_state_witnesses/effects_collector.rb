# ADR-129 G1' witness for :effects_collector. Each call site of the file records its effect decision into the file's
# accumulator while typing, so a collection run installs it around the typing of this file.
class Probe
  def pure(x) = x + 1
  def run = [pure(1), [1, 2].map { |x| x.to_s }, "a".upcase]
end
Probe.new.run
