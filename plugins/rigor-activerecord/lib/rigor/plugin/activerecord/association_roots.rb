# frozen_string_literal: true

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # The model classes ActiveRecord loads BY NAME from an association (`belongs_to :user` → `User`), for
      # `rigor unused` (ADR-102 WD3). The name is derived at runtime and never written in source, so a
      # reference index sees a model reached only this way as unreferenced.
      #
      # The rows come from the {ModelIndex}'s association list, which {ModelDiscoverer} already extracts
      # (class-body declarations and `with_options` groups only — not `class << self`, a `def` or another
      # block). This module only resolves them, mirroring ActiveRecord:
      #
      # - `class_name:` (String or Symbol) wins; `"::Foo"` is rooted.
      # - otherwise `has_many` / `has_and_belongs_to_many` → `name.singularize.camelize`, and
      #   `belongs_to` / `has_one` → `name.camelize` (`Reflection#derive_class_name`).
      # - the name is tried against the owner's lexical nesting, innermost first, then top level
      #   (`ActiveRecord::Inheritance#compute_type`).
      # - a root is published only when the project declares a model of that name.
      #
      # Declined — no root, never a guess: a polymorphic association (no single target), a non-literal
      # `class_name:` / `**opts`, and a `through:` association without a literal `class_name:` /
      # `source_type:`. The latter's class is the SOURCE association's on the through model, and that
      # association (declared on the through model, hence in this same index) roots it itself.
      #
      # The roots are flat: an association on a model `rigor unused` itself reports as dead still roots its
      # target, exactly as the other plugins' roots do.
      module AssociationRoots
        COLLECTION_MACROS = %i[has_many has_and_belongs_to_many].freeze
        ROOTED_MACROS = (COLLECTION_MACROS + %i[belongs_to has_one]).freeze
        VALID_NAME = /\A(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/
        private_constant :VALID_NAME

        module_function

        # Sorted, unique model class names. Raises {Rigor::Plugin::Inflector::Unavailable} when a name had to
        # be inflected and could not be.
        def call(model_index)
          roots = model_index.entries.each_value.flat_map do |entry|
            entry.associations.filter_map { |row| resolve(entry.class_name, row, model_index) }
          end
          roots.uniq.sort
        end

        def resolve(owner, row, model_index)
          return nil unless ROOTED_MACROS.include?(row[:macro])
          return nil if row[:polymorphic]

          type_name = type_name(row)
          return nil if type_name.nil? || !VALID_NAME.match?(type_name)

          candidates(owner, type_name).find { |candidate| model_index.model?(candidate) }
        end

        def type_name(row)
          option = row[:class_name_option]
          return nil if option == :dynamic
          return option unless option.nil?
          return nil if row[:through]

          name = row[:name].to_s
          name = Rigor::Plugin::Inflector.singularize(name) if COLLECTION_MACROS.include?(row[:macro])
          Rigor::Plugin::Inflector.camelize(name)
        end

        # `compute_type`: a rooted name is looked up as is; otherwise the owner's namespaces innermost
        # first, then the top level.
        def candidates(owner, type_name)
          return [type_name.delete_prefix("::")] if type_name.start_with?("::")

          segments = owner.split("::")
          nested = (segments.length - 1).downto(1).map { |n| "#{segments.first(n).join('::')}::#{type_name}" }
          nested + [type_name]
        end
      end
    end
  end
end
