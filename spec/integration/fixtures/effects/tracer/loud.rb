# frozen_string_literal: true

module Tracer
  # The override that makes `Dispatcher#run` impure. Deliberately in a file of its own: the propagator
  # resolves the edge against the ancestry merged from EVERY file's collection, so a per-file view could
  # never see this.
  class Loud < Base
    def emit
      puts("loud")
    end
  end
end
