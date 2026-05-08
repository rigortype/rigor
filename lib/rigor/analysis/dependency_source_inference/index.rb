# frozen_string_literal: true

module Rigor
  module Analysis
    module DependencySourceInference
      # Per-run collection of gem-source-inference state. Holds
      # the resolved gems the walker MAY visit (slice 2b) plus
      # the unresolvable entries the runner SHOULD surface as
      # `dynamic.dependency-source.gem-not-found` diagnostics.
      #
      # Slice 2a lands the data structure only; the dispatcher
      # tier consults {#contribution_for} but the lookup always
      # answers `nil` until slice 2b populates the method table
      # by walking the resolved gems' `roots:`.
      class Index
        attr_reader :resolved_gems, :unresolvable

        def initialize(resolved_gems: [], unresolvable: [])
          @resolved_gems = resolved_gems.freeze
          @unresolvable = unresolvable.freeze
          freeze
        end

        # Slice 2a stub. Slice 2b will return a
        # `Type::Dynamic`-wrapped inferred return type when the
        # walker has visited a definition that matches
        # `(class_name, method_name)`. Until then the dispatcher
        # tier always falls through to the next layer.
        def contribution_for(class_name:, method_name:)
          _ = class_name
          _ = method_name
          nil
        end

        def empty?
          @resolved_gems.empty?
        end
      end

      # Frozen empty index — the runner uses this when
      # `Configuration#dependencies.source_inference` is empty
      # so the dispatcher tier holds a stable, non-nil
      # reference even on default configurations.
      Index::EMPTY = Index.new.freeze
    end
  end
end
