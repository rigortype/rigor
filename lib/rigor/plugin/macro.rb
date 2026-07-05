# frozen_string_literal: true

require_relative "macro/block_as_method"
require_relative "macro/heredoc_template"
require_relative "macro/nested_class_template"
require_relative "macro/trait_registry"

module Rigor
  module Plugin
    # Substrate declarations for the macro / DSL expansion tiers introduced by ADR-16. Plugin authors declare
    # entries under `Plugin::Manifest` slots (`block_as_methods:`, `trait_registries:`, `heredoc_templates:`,
    # `nested_class_templates:`) and the substrate consumes them to recognise the call shapes a library exposes
    # to its users.
    #
    # Tier A (`BlockAsMethod`), Tier B (`TraitRegistry`), Tier C (`HeredocTemplate`), and ADR-36 nested-class
    # emission (`NestedClassTemplate`) value classes are all shipped here. Engine wiring lives in
    # `lib/rigor/inference/`.
    #
    # Per ADR-16 § WD13, substrate-produced output ships at a **floor** in v0.1.x ("substrate-affected code
    # parses cleanly and has its identifiers resolved"); precise return-type emission is the ceiling and arrives
    # in a later slice through the ADR-13 `Plugin::TypeNodeResolver` chain.
    module Macro
    end
  end
end
