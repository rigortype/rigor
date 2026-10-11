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
      module CRubyDefiners
        module_function

        # Does the catalogue prove CRuby defines `method_name` on `class_name` itself?
        def defines?(class_name, method_name)
          names = INDEX[class_name.to_s.delete_prefix("::")]
          !names.nil? && names.include?(method_name.to_s)
        end

        def build_index
          index = Hash.new { |hash, key| hash[key] = Set.new }
          MethodCatalog.topic_paths.each do |path|
            data = YAML.safe_load_file(path, permitted_classes: [Symbol])
            classes = data.is_a?(Hash) ? data["classes"] : nil
            next unless classes.is_a?(Hash)

            classes.each do |name, klass|
              next if klass["rdoc_only"]

              names = index[name]
              names.merge(defined_names(klass["instance_methods"]))
              names.merge(defined_names(klass["aliases"]))
            end
          end
          Ractor.make_shareable(index.to_h { |name, names| [name, names.freeze] })
        rescue Psych::SyntaxError, SystemCallError
          Ractor.make_shareable({})
        end

        # The names of `entries` CRuby defines at runtime: one the catalogue marks `rdoc_only` was registered only for
        # RDoc, inside an `#if 0` block.
        def defined_names(entries)
          return [] unless entries.is_a?(Hash)

          entries.filter_map { |method, entry| method unless entry.is_a?(Hash) && entry["rdoc_only"] }
        end

        INDEX = build_index
        private_constant :INDEX
      end
    end
  end
end
