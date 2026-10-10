# frozen_string_literal: true

require "yaml"
require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # Issue #1740 — which instance methods CRuby itself defines on a core class or module, read from the offline
      # catalogues under `data/builtins/ruby_core/` (`tool/extract_builtin_catalog.rb` records each `rb_define_method`
      # and prelude `def` on the class it names, aliases included). RBS is not that record: core RBS redeclares some
      # inherited methods on a subclass (`Integer#quo` and `File#to_path`, whose CRuby owners are `Numeric` and `IO`),
      # and declares a few CRuby no longer defines (`Process::Status#&`). A class no catalogue covers answers false,
      # as does a method its catalogue does not list: the caller reads both as "not proven".
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
              names = index[name]
              names.merge((klass["instance_methods"] || {}).keys)
              names.merge((klass["aliases"] || {}).keys)
            end
          end
          Ractor.make_shareable(index.to_h { |name, names| [name, names.freeze] })
        rescue Psych::SyntaxError, SystemCallError
          Ractor.make_shareable({})
        end

        INDEX = build_index
        private_constant :INDEX
      end
    end
  end
end
