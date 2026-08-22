# frozen_string_literal: true

# The ancestors, in a file of their own: a `super` is resolved against the MERGED project ancestry, so the
# parent living in another file is the shape that matters — and the one a fork-pool worker has to marshal
# its collection back for.
module SuperEdge
  module Auditing
    def emit(payload)
      File.write("/tmp/audit", payload)
    end
  end

  class BaseWriter
    def emit
      File.read("/etc/hosts")
    end

    def self.build
      puts("built")
    end
  end
end
