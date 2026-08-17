# frozen_string_literal: true

require "logger"

# The per-origin discharge case. `Logger#info` is catalogued `io` + `telemetry` in one bundle, so
# `tolerated: [telemetry]` discharges the whole bundle — the `io` that came with the logging IS the
# logging. `File.read` in the same body is a different origin with a different bundle, and its
# `io.fs.read` survives. Both classes are declared pure by `namespace: "Loggers::*"`.
module Loggers
  class Audit
    def announce
      Logger.new(STDOUT).info("hello")
    end

    def announce_and_read
      Logger.new(STDOUT).info("hello")
      File.read("audit.log")
    end
  end
end
