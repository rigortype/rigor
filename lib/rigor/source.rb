# frozen_string_literal: true

# Source-text and AST positioning utilities.
#
# Anything that maps between a Ruby source buffer and Prism AST nodes belongs
# here. The contents of this namespace deliberately stay independent of the
# inference engine so that future tooling (LSP, refactoring helpers, doc
# extractors) can reuse the same primitives without dragging in `Rigor::Type`.
module Rigor
  module Source
  end
end

require_relative "source/node_locator"
