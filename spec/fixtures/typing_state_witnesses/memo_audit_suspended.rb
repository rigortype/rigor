# ADR-129 G1' witness for :memo_audit_suspended. An audited memo hit recomputes the value with the audit suspended,
# and that recomputation types a callee body whose own memo hits read the flag. `run` calls `helper` and `target`
# repeatedly, so the class-graph and return memos hit.
class Probe
  def helper = [1, 2].map { |x| x + 1 }
  def target(value) = value
  def twice(value) = [target(value), target(value)]
  def run = [helper.first, twice(1), helper.first, twice(1)]
end
Probe.new.run
