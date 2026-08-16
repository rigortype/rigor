# frozen_string_literal: true

require "net/http"
require "uri"

# Fixture app for the ADR-103 effect-envelope slice (#383). Each method exists to exercise one rule of
# the envelope check: the transitive reading, the `mutate.local` carve-out, `%a{pure}` against an ivar
# write, class- and module-level distribution, a per-method override, and the four readings that
# produce NO envelope at all (malformed, empty, unknown label — and the `pure` + `effect` contradiction,
# which does produce one because `pure` wins).
#
# The envelopes themselves live in `sig/envelopes.rbs`; this file carries no Rigor-specific syntax, which
# is the point (ADR-0).
module Envelopes
  class UserRepository
    # Declared `io.db`, but reaches HTTP through a project callee — the envelope binds the method's code
    # transitively, so this exceeds.
    def find(id)
      Gateway.fetch(id)
    end

    # Declared `%a{pure}`. The only thing it does is mutate a buffer its own frame allocated and never
    # lets out, which every envelope tolerates.
    def collect(label)
      buffer = []
      buffer << label
      buffer.length
    end
  end

  class Gateway
    def self.fetch(id)
      Net::HTTP.get(URI("https://example.com/#{id}"))
    end
  end

  class Memo
    # Declared `%a{pure}`, and memoising is a `mutate.self` write — the finding ADR-103 WD4 names.
    def value
      @value ||= 42
    end
  end

  # Class-level `%a{rigor:v1:effect io.db}`: distributes to every method of THIS class.
  class Console
    def shout(message)
      puts(message)
    end

    # A per-method envelope wins over the distributed one; nearest wins.
    def write(message)
      puts(message)
    end
  end

  # Module-level `%a{rigor:v1:effect io.db}`: the module's OWN methods only.
  module Tools
    def self.stamp
      Time.now
    end

    # A class nested in an enveloped module is not a method of that module.
    class Inner
      def tick
        Time.now
      end
    end
  end

  # Four annotations that must not bound anything. Every body here exceeds every plausible bound, so a
  # silent method proves the tag was read as ⊤ rather than as its recognisable part.
  class Quiet
    def malformed
      puts("malformed")
    end

    def empty
      puts("empty")
    end

    def unknown
      puts("unknown")
    end

    # `%a{pure}` and `%a{rigor:v1:effect io.output.stdout}` on one declaration: `pure` wins, so this one
    # DOES fire.
    def conflicted
      puts("conflicted")
    end
  end

  # Class-level `%a{pure}` over synthesised accessors: the writer's `mutate.self` is a finding, the
  # reader's ∅ is not.
  class Bag
    attr_reader :size
    attr_writer :items
  end
end
