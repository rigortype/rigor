# frozen_string_literal: true

require "net/http"
require "uri"

# Fixture app for the ADR-103 declared-lane slice (#386). Two rules share it, because they are two
# readings of one declaration: an envelope on a base method binds its overrides
# (`effect.liskov-widened`), and it bounds what a caller through a base-typed receiver may expect (the
# declared lane at call sites).
#
# The envelopes live in `sig/liskov.rbs` and in the spec's `effects.envelopes:` stanza; this file carries
# no Rigor-specific syntax, which is the point (ADR-0).
module Liskov
  # The base. `sig/liskov.rbs` declares `%a{rigor:v1:effect io.db}` on `find`, and nothing else here
  # declares anything.
  class Repo
    def find(id)
      id.to_s
    end
  end

  # Widens what it DOES: HTTP is not admitted by the inherited `io.db`.
  class PgRepo < Repo
    def find(id)
      Net::HTTP.get(URI("https://example.com/#{id}"))
    end
  end

  # Purer than the bound it inherits. Implementations may be purer, so this stays silent.
  class MemRepo < Repo
    def find(id)
      id.to_s
    end
  end

  # Widens what it DECLARES: the RBS puts `%a{rigor:v1:effect io.net.http}` on this override. The
  # violation is in the declaration, and the body is deliberately pure so that nothing proven could
  # have produced the finding.
  class DeclaredRepo < Repo
    def find(id)
      id.to_s
    end
  end

  # Declares a NARROWER bound than the one it inherits (`%a{pure}` under `io.db`) — correct by
  # construction, and the direction an envelope exists to allow.
  class PureRepo < Repo
    def find(id)
      id.to_s
    end
  end

  # The caller half, kept on a base with no impure override so the assertion is about the DECLARED lane
  # and nothing else: `Reader#fetch` carries `%a{rigor:v1:effect io.db}` and proves nothing, so
  # `Loader#load` reads `∅ ≤ io.db` and its own `io.db` envelope is satisfied.
  class Reader
    def fetch(key)
      key.to_s
    end
  end

  class Loader
    def load(reader)
      reader.fetch("k")
    end
  end

  # The convention half. `Liskov::Conventions::Store` is bounded by an `effects.envelopes:` stanza rather
  # than by an annotation, and both readings have to work through it: `HttpStore` inherits the bound it
  # is not selected by, and `StoreCaller#fetch` imports it at the call site.
  module Conventions
    class Store
      def read(key)
        key.to_s
      end
    end

    class HttpStore < Store
      def read(key)
        Net::HTTP.get(URI("https://example.com/#{key}"))
      end
    end
  end

  class StoreCaller
    def fetch(store)
      store.read("k")
    end
  end
end
