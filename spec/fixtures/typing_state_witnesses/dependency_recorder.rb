# ADR-129 G1' witness for :dependency_recorder. A run with ADR-46 dependency recording on (`record_dependencies: true`,
# as `--incremental` does) installs the consumer's accumulator around the typing of the file, and typing a call to a
# project method or constant files the read into it from inside `type_of`.
module Helper
  LIMIT = 3

  def self.shout(text) = text.upcase
end

class Probe
  def run = [Helper.shout("a"), Helper::LIMIT, helper_local]

  def helper_local = Helper.shout("b")
end
