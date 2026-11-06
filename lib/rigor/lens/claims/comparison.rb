# frozen_string_literal: true

require_relative "../../environment/member_consistency"

module Rigor
  module Lens
    class Claims
      # The deliberately small proof fragment of lens-claims.md. Unknown is not a failed subtype check.
      class Comparison
        def initialize(loader, relative_conflict:)
          @loader = loader
          @proof = Environment::MemberConsistency::RbsProof.new(loader)
          @relative_conflict = relative_conflict
        end

        def call(sub, sup)
          included = sub.map do |arm|
            match = sup.filter_map do |other|
              (rule = inclusion(arm, other)) && evidence(rule, arm, other.display)
            end.first
            match
          end
          return ["compatible", "proven_inclusion", included] if included.none?(nil)

          sub.each do |arm|
            rules = sup.map { |other| disjoint(arm, other) }
            next if rules.any?(nil)

            return ["conflict", "proven_disjoint_arm", [evidence(rules.first, arm, sup.map(&:display).join(" | "))]]
          end
          ["unknown", "unproven", []]
        end

        private

        def evidence(rule, arm, against)
          { "rule" => rule, "arm" => arm.display, "against" => against }
        end

        def inclusion(sub, sup)
          return "equal" if sub.identity == sup.identity
          return nil unless sup.kind == :class && sup.arguments.empty?
          return nil unless @loader.class_type_param_names(sup.value).empty?

          name = sub.kind == :literal ? sub.value.class.name : sub.value
          unreliable = Environment::MemberConsistency::RbsProof::UNRELIABLE_ANCESTRY
          return nil if unreliable.include?(name) || unreliable.include?(sup.value)
          return nil unless @loader.ancestor_names_for(name).include?(sup.value)

          sub.kind == :literal ? "literal_class_ancestor" : "class_ancestor"
        end

        def disjoint(left, right)
          return nil if !@relative_conflict && (left.relative || right.relative)
          return "distinct_literals" if left.kind == :literal && right.kind == :literal && !left.value.eql?(right.value)

          disjoint_classes(left, right)
        end

        def disjoint_classes(left, right)
          left_name = left.kind == :literal ? left.value.class.name : left.value
          right_name = right.kind == :literal ? right.value.class.name : right.value
          left_ancestors = @proof.class_ancestors(left_name)
          right_ancestors = @proof.class_ancestors(right_name)
          return nil if left_ancestors.nil? || right_ancestors.nil?

          if left.kind == :literal
            "literal_outside_class" unless left_ancestors.include?(right_name)
          elsif right.kind == :literal
            "literal_outside_class" unless right_ancestors.include?(left_name)
          elsif !left_ancestors.include?(right_name) && !right_ancestors.include?(left_name)
            "unrelated_classes"
          end
        end
      end
    end
  end
end
