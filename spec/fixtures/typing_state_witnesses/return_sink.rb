# ADR-129 G1' witness for :return_sink. A method body whose `return`s record into the sink the body installs, typed
# from a call site.
class Probe
  def pick(flag)
    return 1 if flag
    return "two" unless flag
    :three
  end
  def run = pick(true)
end
Probe.new.run
