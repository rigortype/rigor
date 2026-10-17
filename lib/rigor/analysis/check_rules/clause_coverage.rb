# frozen_string_literal: true

require "prism"

require_relative "../../inference/narrowing"
require_relative "../../environment/member_consistency"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1485 — whether a `case` clause the engine reads as exhausted by the earlier clauses (`:prior_exhaustion`
      # in {UnreachableClauseCollector}) is dead whatever the subject holds. The engine's `Bot` says only that the
      # earlier clauses covered every member of the subject's type, and a type Rigor inferred or read from a signature
      # may be narrower than what the program holds: `STDOUT` is typed `IO`, a test passes a `StringIO`, which is not an
      # `IO`, and `case io when IO … when StringIO` runs the second arm.
      #
      # So the verdict stands when the subject entering the `case` is made only of carriers that record what the file
      # literally shows (`x = 1; case x when Integer … when String`), or when every class the clause names is at or
      # below a class an earlier clause names (`when IO … when File`, `when Enumerable … when Array`, a repeated
      # `when IO`): any object the clause could match then matches the earlier clause first. The ancestry is RBS's, or
      # the project's own superclass and mixin edges, never past a class whose RBS ancestry Ruby contradicts
      # (`Tempfile`, `< File` in RBS and `< Delegator` in Ruby). A clause that is not a class test (`in [a]`) names no
      # class, so on a non-literal subject it is never proven.
      class ClauseCoverage
        # The carriers issue #1429 counts as literal, plus the value-pinned `nil`, `true` and `false`, whose `Nominal`
        # is the single value itself.
        LITERAL_CARRIERS = [Type::Constant, Type::Tuple, Type::HashShape, Type::Singleton].freeze
        VALUE_PINNED_CLASSES = %w[NilClass TrueClass FalseClass].freeze

        UNRELIABLE_ANCESTRY = Environment::MemberConsistency::RbsProof::UNRELIABLE_ANCESTRY

        # @param scope — the `case` node's scope, which resolves the clauses' class constants.
        # @param subject_type — the subject's type entering the `case`.
        def initialize(scope, subject_type)
          @scope = scope
          @literal_subject = literal?(subject_type)
          @earlier = []
        end

        # Adds the classes `clause` matches by class alone to those a later clause may be covered by: each class
        # condition of a `when` (`when IO, nil` still matches every `IO` first), and the bare class pattern of an `in`.
        def record(clause)
          return if @scope.nil?

          parts = clause.is_a?(Prism::WhenNode) ? clause.conditions : (pattern_alternatives(clause.pattern) || [])
          @earlier.concat(parts.filter_map { |part| class_name(part) })
        end

        # True when the `:prior_exhaustion` verdict on `clause` may stand.
        def proven?(clause)
          return true if @literal_subject
          return false if @scope.nil?

          names = clause_class_names(clause)
          return false if names.nil?

          names.all? do |name|
            ancestors = ancestor_names(name)
            !ancestors.nil? && @earlier.any? { |earlier| ancestors.any? { |ancestor| covered_by?(ancestor, earlier) } }
          end
        end

        private

        def literal?(type)
          members = type.is_a?(Type::Union) ? type.members : [type]
          members.all? do |member|
            LITERAL_CARRIERS.any? { |carrier| member.is_a?(carrier) } ||
              (member.is_a?(Type::Nominal) && VALUE_PINNED_CLASSES.include?(member.class_name))
          end
        end

        # The class names `clause` matches by class alone, or nil when any part of it is something else: every
        # condition of a `when`, and the bare class pattern of an `in` (`in C`, `in C => x`, `in A | B`).
        def clause_class_names(clause)
          parts = clause.is_a?(Prism::WhenNode) ? clause.conditions : pattern_alternatives(clause.pattern)
          return nil if parts.nil? || parts.empty?

          names = parts.map { |part| class_name(part) }
          names.include?(nil) ? nil : names
        end

        def class_name(node)
          return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

          Inference::Narrowing.lexical_class_name(node, @scope)
        end

        def pattern_alternatives(pattern)
          case pattern
          when Prism::CapturePatternNode then pattern_alternatives(pattern.value)
          when Prism::AlternationPatternNode
            left = pattern_alternatives(pattern.left)
            right = pattern_alternatives(pattern.right)
            left && right && (left + right)
          when Prism::ConstantReadNode, Prism::ConstantPathNode then [pattern]
          end
        end

        # `name` and the ancestors the project gives it: the project classes and modules on its chain, and the first
        # candidate the environment knows of each ancestor the project does not declare (`< StandardError`,
        # `include Enumerable`). Nil when the chain was cut, so no coverage rests on part of it.
        def ancestor_names(name)
          return [name] unless @scope.known_user_class?(name)

          external = @scope.external_ancestor_name_candidates(name).map do |candidates|
            candidates.find { |candidate| Reflection.class_known?(candidate, scope: @scope) }
          end
          chain = Scope::ResolutionChain.for(@scope, name, :instance, :methods)
          return nil if chain.truncated?

          ([name] + chain.entries.reject(&:external?).map(&:name) + external.compact).uniq
        end

        # True when every instance of `name` is an instance of `earlier` by the environment's class ordering, past no
        # class whose RBS ancestry Ruby contradicts.
        def covered_by?(name, earlier)
          environment = @scope.environment
          case environment.class_ordering(name, earlier)
          when :equal then true
          when :subclass
            UNRELIABLE_ANCESTRY.none? do |unreliable|
              unreliable != earlier && %i[equal subclass].include?(environment.class_ordering(name, unreliable))
            end
          else false
          end
        end
      end
    end
  end
end
