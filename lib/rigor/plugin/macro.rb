# frozen_string_literal: true

require_relative "macro/block_as_method"

module Rigor
  module Plugin
    # Substrate declarations for the macro / DSL expansion tiers
    # introduced by ADR-16. Plugin authors declare entries under
    # `Plugin::Manifest` slots (`block_as_methods:`,
    # `trait_registries:`, `heredoc_macros:`,
    # `external_file_inclusions:`) and the substrate consumes them
    # to recognise the call shapes a library exposes to its users.
    #
    # Slice 1a (this file's first delivery) ships the Tier A value
    # class only. The other tiers' value classes + their manifest
    # slots arrive in subsequent slices per ADR-16 § Implementation
    # slicing. The namespace is reserved here so subsequent slices
    # add files alongside `block_as_method.rb` without churn.
    #
    # Per ADR-16 § WD13, substrate-produced output ships at a
    # **floor** in v0.1.x ("substrate-affected code parses cleanly
    # and has its identifiers resolved"); precise return-type
    # emission is the ceiling and arrives in a later slice through
    # the ADR-13 `Plugin::TypeNodeResolver` chain.
    module Macro
    end
  end
end
