# frozen_string_literal: true

# `Acme::Http` is the stand-in for a gem: nothing in the project defines it and the effect catalogue has
# no row for it, so the ONLY thing that colours this call is the project's own `effects.attribution:`
# table. That is what makes this method the test of the declared lane — an envelope of `io.db` on it must
# stay silent, because an attributed label is a claim and never a proof.
module Gateways
  class Client
    def fetch(id)
      Acme::Http.get("https://example.com/#{id}")
    end
  end
end
