# frozen_string_literal: true

# `acme.cache` is not a label Rigor ships. `effects.labels:` is how the project opens the root, and this
# call is where the registered spelling is then used — so a run with the vocabulary reports nothing and a
# run without it reports `effect.unknown-label` against the attribution that spells it.
module Caching
  class Client
    def read(key)
      Acme::Cache.fetch(key)
    end
  end
end
