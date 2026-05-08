# frozen_string_literal: true

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Per-run table of method signatures keyed by the
      # `(class_name, method_name, kind)` triple. Built by
      # {CatalogWalker} during the plugin's lazy pre-walk; read
      # by {Sorbet#flow_contribution_for} at every call site.
      #
      # The catalog is mutable while it is being built, then
      # frozen via {#freeze!} before the first read. Construction
      # mutability is intentional — slice 1 builds the catalog
      # incrementally as the walker visits each project file —
      # but consumers MUST treat the catalog as read-only.
      class Catalog
        def initialize
          @entries = {}
          @frozen_after_build = false
        end

        # @param signature [MethodSignature]
        def record(signature)
          raise "Catalog already finalised" if @frozen_after_build

          key = key_for(signature.class_name, signature.method_name, signature.kind)
          @entries[key] = signature
        end

        def freeze!
          @frozen_after_build = true
          @entries.freeze
          freeze
        end

        # @return [MethodSignature, nil]
        def lookup(class_name:, method_name:, kind:)
          @entries[key_for(class_name, method_name, kind)]
        end

        def empty?
          @entries.empty?
        end

        def size
          @entries.size
        end

        private

        def key_for(class_name, method_name, kind)
          [class_name.to_s, method_name.to_sym, kind]
        end
      end
    end
  end
end
