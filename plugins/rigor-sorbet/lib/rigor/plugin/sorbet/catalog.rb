# frozen_string_literal: true

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Per-run table of method signatures keyed by the
      # `(class_name, method_name, kind)` triple. Built by
      # {CatalogWalker} during the plugin's lazy pre-walk; read
      # by the plugin's `dynamic_return` rule at every gated call site.
      #
      # The catalog is mutable while it is being built, then
      # frozen via {#freeze!} before the first read. Construction
      # mutability is intentional — slice 1 builds the catalog
      # incrementally as the walker visits each project file —
      # but consumers MUST treat the catalog as read-only.
      class Catalog
        # Frozen empty bucket reused for classes that have no
        # recorded mixins. Avoids allocating a fresh Hash on
        # every `mixins_for` query.
        EMPTY_MIXINS = { include: [].freeze, extend: [].freeze }.freeze

        def initialize
          @entries = {}
          # ADR-11 slice 8 — per-class mixin declarations
          # collected by `CatalogWalker`. Lookup-time chain
          # traversal lifts sigs declared on a mixed-in
          # module to call sites on the host class.
          @mixins = {}
          @frozen_after_build = false
        end

        # @param signature [MethodSignature]
        def record(signature)
          raise "Catalog already finalised" if @frozen_after_build

          key = key_for(signature.class_name, signature.method_name, signature.kind)
          @entries[key] = signature
        end

        # @param class_name [String] the class / module that
        #   carries the mixin (`class Post; include Foo; end`
        #   records under `"Post"`).
        # @param kind [:include, :extend]
        # @param module_name [String] the textual name of the
        #   mixed-in module as it appeared at the include /
        #   extend site (`"Foo"`, `"Foo::Bar"`, `"::Foo"`).
        def record_mixin(class_name:, kind:, module_name:)
          raise "Catalog already finalised" if @frozen_after_build

          bucket = (@mixins[class_name] ||= { include: [], extend: [] })
          list = bucket[kind]
          list << module_name unless list.include?(module_name)
        end

        def freeze!
          @frozen_after_build = true
          @entries.freeze
          @mixins.each_value do |bucket|
            bucket.each_value(&:freeze)
            bucket.freeze
          end
          @mixins.freeze
          freeze
        end

        # @return [MethodSignature, nil]
        def lookup(class_name:, method_name:, kind:)
          @entries[key_for(class_name, method_name, kind)]
        end

        # @param class_name [String]
        # @return [Hash{Symbol => Array<String>}] frozen mapping
        #   `{ include: [...], extend: [...] }`. Returns
        #   {EMPTY_MIXINS} when no mixins were recorded.
        def mixins_for(class_name)
          @mixins[class_name] || EMPTY_MIXINS
        end

        def empty?
          @entries.empty?
        end

        # ADR-52 slice 4 — the distinct method names the catalog
        # carries at least one signature for, across every
        # `(class_name, kind)` owner. Feeds the plugin's run-time
        # `dynamic_return methods:` name gate: the engine only
        # consults the plugin for a call whose name appears here
        # (or in the static assertion vocabulary), and the
        # precise `(class, kind)` lookup stays in the rule block.
        # Computed fresh per call — the plugin memoises the
        # resolved set, and `freeze!` freezes the catalog itself
        # so a lazy memo ivar here would raise.
        #
        # @return [Array<Symbol>]
        def method_names
          @entries.keys.map { |key| key[1] }.uniq
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
