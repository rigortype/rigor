# ADR-129 G1' witness for :next_sink, :break_sink and :break_value_sink. Blocks and loops whose `next` and `break`
# record into the sinks their body installs, so the value of each construct is the join of its exits.
class Probe
  def run
    a = [1, 2, 3].map { |x| next "s" if x > 1; x }
    b = [1, 2, 3].each { |x| break :hit if x > 1 }
    i = 0
    c = while i < 3
          i += 1
          break i.to_s if i > 1
        end
    [a, b, c]
  end
end
Probe.new.run
