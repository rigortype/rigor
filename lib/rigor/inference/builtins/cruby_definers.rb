# frozen_string_literal: true

require "yaml"
require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # Issue #1740 — which instance methods CRuby itself defines on a core class or module, read from the offline
      # catalogues under `data/builtins/ruby_core/` (`tool/extract_builtin_catalog.rb` records each `rb_define_method`
      # and prelude `def` of an `Init_*` function on the class it names, aliases included). A registration inside an
      # `#if 0` block CRuby keeps for RDoc carries `rdoc_only: true` and is left out: `random.c`'s registers
      # `Random#seed` on `Random`, though it runs on `Random::Base`.
      # `spec/rigor/inference/builtins/c_ruby_definers_spec.rb` checks every listed method the running Ruby has
      # against its runtime owner. RBS is not that record: core RBS redeclares some inherited methods on a subclass
      # (`Integer#quo` and `File#to_path`, whose CRuby owners are `Numeric` and `IO`), and declares a few CRuby no
      # longer defines (`Process::Status#&`). A class no catalogue covers answers false, as does a method its
      # catalogue does not list: the caller reads both as "not proven". The catalogue is one CRuby snapshot.
      #
      # Issue #1752 — the singleton side reads the catalogue's `singleton_methods` (each `rb_define_singleton_method`
      # on the class), the record that `Integer.sqrt` is CRuby's own method of `Integer`'s singleton class.
      module CRubyDefiners
        module_function

        # Does the catalogue prove CRuby defines `method_name` on `class_name` itself?
        def defines?(class_name, method_name)
          names = INDEX[class_name.to_s.delete_prefix("::")]
          !names.nil? && names.include?(method_name.to_s)
        end

        # Does the catalogue prove CRuby defines `method_name` on `class_name`'s singleton class itself?
        def singleton_defines?(class_name, method_name)
          names = SINGLETON_INDEX[class_name.to_s.delete_prefix("::")]
          !names.nil? && names.include?(method_name.to_s)
        end

        # `{class name => Set[method name]}` from each catalogued class's instance methods and aliases, or from its
        # `singleton_methods` when `side` is `:singleton`.
        def build_index(side = :instance)
          index = Hash.new { |hash, key| hash[key] = Set.new }
          MethodCatalog.topic_paths.each do |path|
            data = YAML.safe_load_file(path, permitted_classes: [Symbol])
            classes = data.is_a?(Hash) ? data["classes"] : nil
            next unless classes.is_a?(Hash)

            classes.each do |name, klass|
              next if klass["rdoc_only"]

              merge_names(index[name], klass, side)
            end
          end
          Ractor.make_shareable(index.to_h { |name, names| [name, names.freeze] })
        rescue Psych::SyntaxError, SystemCallError
          Ractor.make_shareable({})
        end

        def merge_names(names, klass, side)
          return names.merge(defined_names(klass["singleton_methods"])) if side == :singleton

          names.merge(defined_names(klass["instance_methods"]))
          names.merge(defined_names(klass["aliases"]))
        end

        # The names of `entries` CRuby defines at runtime: one the catalogue marks `rdoc_only` was registered only for
        # RDoc, inside an `#if 0` block.
        def defined_names(entries)
          return [] unless entries.is_a?(Hash)

          entries.filter_map { |method, entry| method unless entry.is_a?(Hash) && entry["rdoc_only"] }
        end

        INDEX = build_index
        SINGLETON_INDEX = build_index(:singleton)
        private_constant :INDEX, :SINGLETON_INDEX
      end
    end
  end
end
