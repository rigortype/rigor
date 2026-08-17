# frozen_string_literal: true

# Fixture app for the ADR-103 config-policy slice (#385). Selected by a `match:` path glob —
# `app/presenters/**/*.rb`, `effect: []` — so the layer is declared pure by convention and nothing here
# carries Rigor syntax. The one exception is `annotated`, whose per-method envelope in `sig/policy.rbs`
# must win over the configured one.
module Presenters
  class User
    def name
      @name.to_s
    end

    # Reads the filesystem under an empty envelope: the finding the `match:` stanza exists to produce.
    def render
      File.read("template.erb")
    end

    # Same body, but `sig/policy.rbs` declares `%a{rigor:v1:effect io.fs.read}` on it — nearest wins.
    def annotated
      File.read("other.erb")
    end
  end
end
