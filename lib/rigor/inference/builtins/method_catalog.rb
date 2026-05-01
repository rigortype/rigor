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

        def initialize(path:, mutating_selectors: {})
          @path = path
          @mutating_selectors = mutating_selectors.transform_values(&:freeze).freeze
          @catalog = nil
        end

        def safe_for_folding?(class_name, selector, kind: :instance)
          class_name_str = class_name.to_s
          return false if blocked?(class_name_str, selector)

          entry = method_entry(class_name_str, selector, kind: kind)
          return false unless entry

          FOLDABLE_PURITIES.include?(entry["purity"])
        end

        def method_entry(class_name, selector, kind: :instance)
          klass = catalog.dig("classes", class_name.to_s)
          return nil unless klass

          bucket_key = kind == :singleton ? "singleton_methods" : "instance_methods"
          klass.dig(bucket_key, selector.to_s)
        end

        def reset!
          @catalog = nil
        end

        private

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

        def catalog
          @catalog ||= load_catalog
        end

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
