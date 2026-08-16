# frozen_string_literal: true

module Tracer
  # The base of the closed-world override join: `Dispatcher#run` calls `Base#emit`, and the project
  # defines an override of it in ANOTHER file (`loud.rb`), so the caller's summary is the union over
  # both bodies. Ruby has no `final`, and the analyzer takes the same closed-world posture for effects
  # that it already takes for types (ADR-103 WD4).
  class Base
    def emit
      "quiet"
    end
  end

  class Dispatcher
    def run
      Base.new.emit
    end
  end
end
