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

  # Slice 2 assertion stubs so `ruby demo.rb` runs without
  # `sorbet-runtime` installed. rigor-sorbet only reads the
  # syntactic shape of the call; the runtime body returns the
  # inner expression unchanged, mirroring `sorbet-runtime`.
  def self.let(value, _type) = value
  def self.cast(value, _type) = value
  def self.must(value) = value
  def self.unsafe(value) = value
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

# ADR-11 slice 2 — type-assertion calls. T.let / T.cast / T.must
# / T.unsafe are recognised at the call site and contribute the
# asserted return type directly.
counter = T.let(0, Integer)
counter += 1
puts(counter.even?.inspect)

# T.must strips nil from a nilable type so chained calls
# resolve on the inner type alone. The literal initialiser
# is `42` here so the runtime path also works without nil
# handling; the rigor-sorbet contribution comes from the
# `T.let` widening the type to `T.nilable(Integer)`.
maybe_id = T.let(42, T.nilable(Integer))
puts(T.must(maybe_id).bit_length)

# T.unsafe falls back to Dynamic[top] so the analyzer silences
# call-site existence checks.
opaque = T.unsafe(Slug.default_length)
puts(opaque)
