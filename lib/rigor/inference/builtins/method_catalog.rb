# frozen_string_literal: true

require "yaml"

module Rigor
  module Inference
    module Builtins
      # Generic loader for offline-generated catalogs under
      # `data/builtins/ruby_core/<topic>.yml`. One instance per topic
      # (numeric, string, array, …); each owns the path to its own
      # YAML and the per-class blocklist of selectors the static
      # classifier marked `:leaf` but that actually mutate the
      # receiver (false positives the C-body heuristic does not
      # catch).
      #
      # `safe_for_folding?(class_name, selector, kind:)` returns true
      # when:
      # 1. The catalog has an entry for `(class_name, selector, kind)`,
      # 2. The entry's `purity` is one of `leaf` / `trivial` /
      #    `leaf_when_numeric`,
      # 3. The selector is NOT in the per-class mutation blocklist.
      #
      # Missing catalog files (e.g. in a bare gem install where data
      # was opted out) degrade to `false` so the dispatcher falls
      # back to its hand-rolled allow lists.
      class MethodCatalog
        FOLDABLE_PURITIES = Set["leaf", "trivial", "leaf_when_numeric"].freeze
        EMPTY_CATALOG = { "classes" => {} }.freeze

        # Selectors that are classified `:leaf` by the C-body analysis
        # (they read no global mutable state in the C sense) but whose
        # result is NOT reproducible across Ruby processes, so they must
        # never be folded into a `Constant`:
        #
        # - `hash` — every core `#hash` (`String`/`Symbol`/`Integer`/
        #   `Float`/…) is salted with a per-process SipHash seed, so
        #   `"x".hash` differs in every process. Folding bakes one
        #   process's value into the type and the on-disk cache.
        # - `object_id` / `__id__` — identity-allocated per process.
        #
        # This is a UNIVERSAL block (across every catalogued class)
        # because `hash` / `object_id` are `Object`-level and present on
        # every receiver; a per-class blocklist would silently miss a
        # class. The deterministic siblings (`inspect`, `to_s`) are
        # unaffected.
        NON_REPRODUCIBLE_SELECTORS = Set[:hash, :object_id, :__id__].freeze

        # Shared root for the offline-generated catalogues. Resolving it
        # here keeps the repo-relative `../../../../` hop in one place
        # instead of copying it into every per-topic loader.
        DATA_ROOT = File.expand_path("../../../../data/builtins/ruby_core", __dir__)
        private_constant :DATA_ROOT

        # Build a catalog for a named topic, resolving its YAML path
        # under {DATA_ROOT}. Equivalent to `new(path: …)` for the common
        # case where the file is `<topic>.yml`; prefer this over passing
        # an explicit `File.expand_path` so the data-root hop stays
        # centralised.
        def self.for_topic(topic, mutating_selectors: {})
          new(path: File.join(DATA_ROOT, "#{topic}.yml"), mutating_selectors: mutating_selectors)
        end

        def initialize(path:, mutating_selectors: {})
          @path = path
          @mutating_selectors = mutating_selectors.transform_values(&:freeze).freeze
          # ADR-15 Phase 4b.x — eager-load so the instance is
          # safe to `Ractor.make_shareable`. Lazy init via
          # `@catalog ||= load_catalog` would write to a
          # potentially-frozen instance the first time a
          # worker Ractor consults the catalog, raising
          # `FrozenError`. The YAML parse is a once-per-process
          # cost and the catalogs are constructed at module
          # load time anyway, so eager init is free in
          # practice.
          @catalog = load_catalog
        end

        def safe_for_folding?(class_name, selector, kind: :instance)
          class_name_str = class_name.to_s
          return false if NON_REPRODUCIBLE_SELECTORS.include?(selector.to_sym)
          return false if blocked?(class_name_str, selector)

          entry = method_entry(class_name_str, selector, kind: kind)
          return false unless entry

          FOLDABLE_PURITIES.include?(entry["purity"])
        end

        def method_entry(class_name, selector, kind: :instance)
          klass = catalog.dig("classes", class_name.to_s)
          return nil unless klass

          bucket_key = kind == :singleton ? "singleton_methods" : "instance_methods"
          klass.dig(bucket_key, selector.to_s) ||
            resolve_alias_entry(klass, selector, bucket_key)
        end

        def reset!
          @catalog = load_catalog
        end

        private

        def resolve_alias_entry(klass, selector, bucket_key)
          return nil unless bucket_key == "instance_methods"

          aliases = klass["aliases"]
          return nil unless aliases

          alias_entry = aliases[selector.to_s]
          return nil unless alias_entry

          target = alias_entry["old"]
          return nil unless target

          klass.dig(bucket_key, target)
        end

        def blocked?(class_name, selector)
          # Bang-suffixed selectors are mutating by Ruby convention
          # (`upcase!`, `concat`, etc. are listed explicitly below;
          # this catches the rest). We bias toward false negatives:
          # losing a fold opportunity is acceptable; folding a
          # mutator is not.
          selector_str = selector.to_s
          return true if selector_str.end_with?("!")

          per_class = @mutating_selectors[class_name]
          return false if per_class.nil?

          per_class.include?(selector.to_sym) || per_class.include?(selector_str.to_sym)
        end

        attr_reader :catalog

        def load_catalog
          return EMPTY_CATALOG unless File.exist?(@path)

          data = YAML.safe_load_file(@path, permitted_classes: [Symbol])
          data.is_a?(Hash) ? data : EMPTY_CATALOG
        rescue Psych::SyntaxError
          EMPTY_CATALOG
        end
      end
    end
  end
end
