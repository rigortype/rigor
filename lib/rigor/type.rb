# frozen_string_literal: true

module Rigor
  # Documentation-only ducktype module that names the contract every Rigor
  # type instance MUST satisfy. Concrete type classes do NOT include
  # Rigor::Type; the ducktype is observed structurally.
  #
  # See docs/internal-spec/internal-type-api.md for the binding contract.
  module Type
  end
end

require_relative "type/top"
require_relative "type/bot"
require_relative "type/dynamic"
require_relative "type/nominal"
require_relative "type/singleton"
require_relative "type/constant"
require_relative "type/union"
require_relative "type/combinator"
