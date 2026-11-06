# ADR-129 G1' witness for :retry_frames. A `retry` edge records the raise points of its primary body.
class Probe
  def run
    attempts = 0
    begin
      attempts += 1
      raise "boom" if attempts < 2
      attempts
    rescue RuntimeError
      retry if attempts < 3
      nil
    end
  end
end
Probe.new.run
