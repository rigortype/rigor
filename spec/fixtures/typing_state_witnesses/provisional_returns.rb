# ADR-129 G1' witness for :provisional_returns. The outer block is folded, which suppresses threading for the inner
# block, so the inner block's tail is typed alone (#2299) and its `return` is filed as provisional.
class Probe
  def first_truthy(groups)
    groups.map do |group|
      label = group.to_s
      group.each do |e|
        r = e.to_s + label
        return r if r
      end
    end
  end
  def run = first_truthy([[1], [2]])
end
Probe.new.run
