# frozen_string_literal: true

require "yaml"

module Rigor
  module Inference
    module Builtins
      # Read-only loader for the Numeric/Integer/Float built-in method
      # catalog at `data/builtins/ruby_core/numeric.yml`. The catalog is
      # produced offline by `tool/extract_numeric_catalog.rb` from the
      # CRuby reference checkout under `references/ruby` plus the RBS
      # core signatures under `references/rbs`.
      #
      # The loader is the runtime bridge: callers ask "is `Integer#+`
      # safe to invoke during constant folding?" and the answer comes
      # straight from the offline classification (`leaf`, `trivial`,
      # `leaf_when_numeric` are foldable; everything else is not).
      #
      # The catalog is loaded lazily on first access and memoised for
      # the lifetime of the process. If the file is missing (e.g. in a
      # bare gem install where the consumer opted out of shipping data
      # files, or in a development checkout that has not yet generated
      # the catalog) the loader degrades to an empty catalog so calls
      # uniformly return `false` and the rest of the dispatcher
      # continues with its hand-rolled allow lists.
      module NumericCatalog
        # Purity tags from the catalog that are safe for the analyzer
        # to invoke against concrete literal receivers/arguments.
        # `leaf_when_numeric` is included because `ConstantFolding`
        # only lets it through when every argument is itself a
        # `Constant<Numeric>` or `IntegerRange` — exactly the gate
        # the catalog tag is named for.
        FOLDABLE_PURITIES = Set["leaf", "trivial", "leaf_when_numeric"].freeze

        EMPTY_CATALOG = { "classes" => {} }.freeze
        private_constant :EMPTY_CATALOG

        # Path resolved relative to this file. The catalog ships under
        # `data/builtins/ruby_core/numeric.yml` at the gem root.
        CATALOG_PATH = File.expand_path(
          "../../../../data/builtins/ruby_core/numeric.yml",
          __dir__
        )
        private_constant :CATALOG_PATH

        class << self
          # @param class_name [String] e.g. "Integer", "Float"
          # @param selector [Symbol, String]
          # @param kind [Symbol] :instance (default) or :singleton
          # @return [Boolean]
          def safe_for_folding?(class_name, selector, kind: :instance)
            entry = method_entry(class_name, selector, kind: kind)
            return false unless entry

            FOLDABLE_PURITIES.include?(entry["purity"])
          end

          # @return [Hash, nil] catalog entry for the given method, or
          #   nil when the method is not registered.
          def method_entry(class_name, selector, kind: :instance)
            klass = catalog.dig("classes", class_name.to_s)
            return nil unless klass

            bucket_key = kind == :singleton ? "singleton_methods" : "instance_methods"
            klass.dig(bucket_key, selector.to_s)
          end

          # Used by tests to drop the cached catalog so a different
          # path or content can be exercised. Production code MUST
          # NOT call this during normal operation.
          def reset!
            @catalog = nil
          end

          private

          def catalog
            @catalog ||= load_catalog
          end

          def load_catalog
            return EMPTY_CATALOG unless File.exist?(CATALOG_PATH)

            data = YAML.safe_load_file(CATALOG_PATH, permitted_classes: [Symbol])
            data.is_a?(Hash) ? data : EMPTY_CATALOG
          rescue Psych::SyntaxError
            EMPTY_CATALOG
          end
        end
      end
    end
  end
end
