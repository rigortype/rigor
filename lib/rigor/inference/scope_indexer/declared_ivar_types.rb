# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../rbs_type_translator"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #1406 — an ivar the class's RBS declares, as `@x: T` or through an `attr_reader x: T` /
      # `attr_writer` / `attr_accessor` member (in `sig/`, or inline `attr_reader :x #: T`), reads the declared type
      # in place of the census's join of the writes. The declaration is the author's contract for the field, so it
      # wins over every write the census saw, #541's untyped `attr_writer` write included; whether the writes honour it is ADR-112 WD5's question (#1075), not this one's. It serves
      # checking only: `rigor sig-gen` indexes with `declared_ivar_types: false` and keeps the census's answer.
      #
      # Only an ivar the census already holds is replaced, so a declaration adds no entry the file's writes did not.
      # A declaration is not taken when it is `untyped` (what rbs-inline supplies for a bare `attr_reader :x`, which
      # the type specification reads as a placeholder) or mentions a type variable (`@x: T` in `class Box[T]` is
      # unsolved at a read), and the census entry stands.
      module DeclaredIvarTypes
        module_function

        def apply!(accumulator, scope)
          environment = scope&.environment
          return if environment.nil?

          accumulator.each do |class_name, entries|
            next unless class_name.is_a?(String) # a guard: the side-table keys are deleted before this runs

            declared = declared_ivars(class_name, environment)
            next if declared.empty?

            accumulator[class_name] = entries.to_h do |ivar, type|
              [ivar, declared.fetch(ivar, type)]
            end
          end
        end

        # `{ivar name => Rigor::Type}` for the ivars `class_name`'s RBS instance definition declares with a usable
        # type, or `{}`.
        def declared_ivars(class_name, environment)
          definition = Reflection.instance_definition(class_name, environment: environment)
          return {} if definition.nil?

          instance = Type::Combinator.nominal_of(class_name)
          definition.instance_variables.each_with_object({}) do |(name, variable), acc|
            type = translate(variable.type, instance, environment)
            acc[name] = type if type
          end
        rescue StandardError # a guard: a definition that fails to build declares nothing
          {}
        end

        def translate(rbs_type, instance, environment)
          return nil unless rbs_type.free_variables.empty?

          type = RbsTypeTranslator.translate(rbs_type, self_type: instance, instance_type: instance,
                                                       alias_expander: environment.rbs_loader)
          type.is_a?(Type::Dynamic) ? nil : type
        end
      end
    end
  end
end
