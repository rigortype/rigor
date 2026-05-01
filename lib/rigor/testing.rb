# frozen_string_literal: true

module Rigor
  # Slice 7 phase 19 — PHPStan-style typing helpers.
  #
  # `Rigor::Testing` ships two runtime no-op helpers that serve
  # as anchors for static-analysis diagnostics:
  #
  # - `dump_type(value)` — returns `value` unchanged at runtime.
  #   The Rigor analyzer surfaces an `:info`-severity diagnostic
  #   at the call site showing the inferred type of `value` so
  #   the user can see what the engine sees at that program point.
  # - `assert_type(expected, value)` — returns `value` unchanged
  #   at runtime. The analyzer compares `value`'s inferred type
  #   (rendered through `Rigor::Type#describe(:short)`) against
  #   the literal `expected` String; a mismatch produces an
  #   `:error`-severity diagnostic. This lets a user-written
  #   fixture be self-asserting: `rigor check fixture.rb` exits
  #   non-zero exactly when the engine's inference drifts from
  #   what the fixture documents.
  #
  # Three usage shapes are recognised by the static rules:
  #
  #   require "rigor/testing"
  #   include Rigor::Testing
  #   dump_type(x)
  #   assert_type("Constant[1]", x)
  #
  # ... or fully qualified:
  #
  #   Rigor::Testing.dump_type(x)
  #   Rigor::Testing.assert_type("String | nil", x)
  #
  # ... or via the convenience top-level alias `Rigor` itself:
  #
  #   Rigor.dump_type(x)
  #   Rigor.assert_type("Constant[\"hello\"]", x)
  #
  # All three resolve to the same no-op runtime body, so a
  # fixture may freely run under MRI without depending on the
  # analyzer being present.
  module Testing
    module_function

    def dump_type(value)
      value
    end

    def assert_type(_expected, value)
      value
    end
  end

  class << self
    # Convenience aliases on `Rigor` itself, so fixtures can
    # write `Rigor.dump_type(x)` without an `include` line.
    def dump_type(value)
      Testing.dump_type(value)
    end

    def assert_type(expected, value)
      Testing.assert_type(expected, value)
    end
  end
end
