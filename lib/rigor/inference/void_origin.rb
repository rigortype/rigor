# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-100 WD3 — the resolved `-> void` origin site recorded in {Rigor::Scope#void_origins}. A small cause
    # record, never a carrier field: it says *which* author-declared `-> void` return was recovered to `top`
    # at a use site, so the `static.value-use.void` diagnostic can name it. Mirrors the provenance-as-
    # side-channel discipline {DynamicOrigin} established (ADR-75) — it never participates in subtyping,
    # consistency, normalization, or erasure.
    #
    # @!attribute class_name
    #   @return [String] the receiver class whose method declared `-> void`.
    # @!attribute method_name
    #   @return [Symbol] the method whose return was recovered.
    # @!attribute kind
    #   @return [Symbol] `:instance` or `:singleton`.
    VoidOrigin = Data.define(:class_name, :method_name, :kind) do
      # A human-facing `Class#method` / `Class.method` label for the diagnostic message.
      def label
        separator = kind == :singleton ? "." : "#"
        "#{class_name}#{separator}#{method_name}"
      end
    end
  end
end
