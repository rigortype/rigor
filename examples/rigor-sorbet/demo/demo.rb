# frozen_string_literal: true

# Demo: rigor-sorbet picks up `sig { ... }` blocks above each
# method and contributes the parsed return type at every call
# site. Run with `bundle exec rigor check` from this directory.
#
# Note: this demo intentionally does NOT require `sorbet-runtime`,
# so we stub `extend T::Sig` and the `sig` method as no-ops.
# rigor-sorbet only reads the syntactic shape of the `sig`
# blocks; the runtime implementation is irrelevant to the
# static analyzer.

module T
  module Sig
    # `sig` is a no-op at runtime in this demo — see header.
    def sig(*, &) = nil
  end
end

class Slug
  extend T::Sig

  sig { params(name: String).returns(String) }
  def normalise(name)
    name.downcase.gsub(/\s+/, "-")
  end

  sig { returns(Integer) }
  def self.default_length
    32
  end
end

# rigor-sorbet contributes `Slug.default_length`'s return as
# `Integer`, so the chained `.even?` resolves through the
# analyzer's normal Integer dispatch.
length_is_even = Slug.default_length.even?

# Calls on instance receivers also resolve through the catalog
# when the receiver type is known to be `Nominal["Slug"]`.
slug = Slug.new
slug_for_alice = slug.normalise("Alice Doe")

# Demo helpers that exercise the catalog from the value side.
puts(slug_for_alice)
puts(length_is_even.inspect)
