# frozen_string_literal: true

# Bounded by a `match:`-selected `effects.envelopes:` stanza rather than by an annotation. The
# envelope index drops `match:` entries — a path glob is a fact a per-file collection window cannot
# see — so emission matches the entry against the candidate's own defining file instead.
module Annotated
  class Presented
    def title
      "x"
    end
  end
end
