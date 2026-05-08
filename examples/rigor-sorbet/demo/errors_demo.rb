# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-sorbet's diagnostics.
#
# Each example is intentionally malformed at the `sig`-syntax
# level, exercising the `plugin.sorbet.parse-error` warnings.

module T
  module Sig
    def sig(*, &) = nil
  end
end

class Adder
  extend T::Sig

  # Missing terminus: neither `.returns(...)` nor `.void`.
  # Expected diagnostic:
  #   plugin.sorbet.parse-error
  #   Sorbet `sig` block must end in `.returns(...)` or `.void`.
  sig { params(left: Integer, right: Integer) }
  def add(left, right)
    left + right
  end

  # Sig is not immediately followed by a method definition; the
  # intervening `puts` call breaks the pairing.
  # Expected diagnostic:
  #   plugin.sorbet.parse-error
  #   `sig` block is not immediately followed by a method definition.
  sig { returns(Integer) }
  puts "this puts call breaks the pairing"

  def stranded
    42
  end

  # Two consecutive sigs — the first has no def to attach to.
  # Expected diagnostic:
  #   plugin.sorbet.parse-error
  #   Two `sig` blocks in a row; the first one has no following method definition.
  sig { returns(String) }
  sig { returns(Integer) }
  def doubled
    1
  end
end
