# frozen_string_literal: true

require "logger"

# Fixture app for ADR-103 WD9 — `rigor sig-gen`'s annotation-emission slot (#391). One class per
# decision the emitter has to make, and nothing else; the project carries no Rigor-specific syntax,
# which is the point (ADR-0). `sig/` is deliberately empty so every method classifies `new-method`
# and the writer's create path is what the round-trip exercises.
module Annotated
  # Exhaustive, undischarged, nothing outside `mutate.local`: the one shape that earns `%a{pure}`.
  class Pure
    def label
      buffer = []
      buffer << "a"
      buffer.length
    end
  end

  # Exhaustive and undischarged, but with a real footprint. Nothing under the default flag; a
  # `%a{rigor:v1:effect io.output.stdout}` under `--effect-envelopes`.
  class Loud
    def shout
      puts("hi")
      1
    end
  end

  # The fourth invariant: the whole proven footprint arrives through a `telemetry` origin the project
  # tolerates, so the judgment reads clean and the RECORD does not. A `%a{pure}` here would state
  # what the project agreed to ignore rather than what the code does.
  class Chatty
    def note
      logger = Logger.new(nil)
      logger.info("noted")
      2
    end
  end

  # Non-exhaustive: the receiver is unknown, so the summary reads "these effects, and possibly more".
  class Opaque
    def dispatch(target)
      target.perform
      3
    end
  end
end
