# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # Shared dispatch table for `Rigor::Type#accepts(other, mode:)`.
    #
    # The acceptance query answers "is `other` passable to `self` at a
    # method-parameter or assignment boundary?". It uses gradual-typing
    # rules from docs/type-specification/value-lattice.md and the
    # acceptance contract in docs/internal-spec/internal-type-api.md.
    #
    # Each concrete type's `accepts` method delegates here so the
    # case-analysis stays in one place. Type instances remain thin value
    # objects; routing logic lives in the inference layer.
    #
    # Slice 4 phase 2c implements the `:gradual` mode in full and
    # reserves `:strict` for later slices (the entry point raises
    # ArgumentError on strict for now). The table covers the leaf and
    # combinator types added through phase 2b: Top, Bot, Dynamic,
    # Nominal, Singleton, Constant, and Union.
    #
    # Slice 5 registers the shape carriers `Tuple` and `HashShape`.
    # Tuple/HashShape acceptance compares per-position element types
    # (covariant) and per-key entry types (depth covariant), including
    # HashShape required/optional/closed-extra-key policy. When the
    # receiver side is a
    # generic `Nominal[Array, [E]]` or `Nominal[Hash, [K, V]]` the
    # shape is projected to its underlying nominal so the existing
    # generic-acceptance pipeline continues to apply; the converse
    # direction (a Tuple receiver accepting a generic Array) stays
    # conservative because the analyzer cannot verify arity from a
    # raw nominal alone.
    # rubocop:disable Metrics/ModuleLength
    module Acceptance
      module_function

      # @param self_type [Rigor::Type]
      # @param other_type [Rigor::Type]
      # @param mode [Symbol] `:gradual` (default) or `:strict`.
      # @return [Rigor::Type::AcceptsResult]
      def accepts(self_type, other_type, mode: :gradual)
        raise ArgumentError, "Acceptance mode #{mode.inspect} is not implemented yet" unless mode == :gradual

        return Type::AcceptsResult.yes(mode: mode, reasons: "Bot is the empty type") if other_type.is_a?(Type::Bot)
        if other_type.is_a?(Type::Dynamic)
          return Type::AcceptsResult.yes(mode: mode, reasons: "gradual: Dynamic[T] passes any boundary")
        end
        return accepts_union_other(self_type, other_type, mode) if other_type.is_a?(Type::Union)

        accepts_one(self_type, other_type, mode)
      end

      # Hash dispatch keeps `accepts_one` linear and lets future shape
      # carriers register their handlers without re-tripping the
      # cyclomatic budget on a growing `case` arm. Anonymous Type
      # subclasses are not expected.
      TYPE_HANDLERS = {
        Type::Top => :accepts_top,
        Type::Bot => :accepts_bot,
        Type::Dynamic => :accepts_dynamic,
        Type::Union => :accepts_union_self,
        Type::Singleton => :accepts_singleton,
        Type::Nominal => :accepts_nominal,
        Type::Constant => :accepts_constant,
        Type::IntegerRange => :accepts_integer_range,
        Type::Difference => :accepts_difference,
        Type::Refined => :accepts_refined,
        Type::Tuple => :accepts_tuple,
        Type::HashShape => :accepts_hash_shape
      }.freeze
      private_constant :TYPE_HANDLERS

      # rubocop:disable Metrics/ClassLength
      class << self
        private

        def accepts_one(self_type, other_type, mode)
          handler = TYPE_HANDLERS[self_type.class]
          return send(handler, self_type, other_type, mode) if handler

          Type::AcceptsResult.maybe(mode: mode, reasons: "no rule for self=#{self_type.class}")
        end

        def accepts_top(_self_type, _other_type, mode)
          Type::AcceptsResult.yes(mode: mode, reasons: "Top is the universal type")
        end

        def accepts_bot(_self_type, other_type, mode)
          # Other is not Bot here (handled in {.accepts}), so Bot rejects it.
          Type::AcceptsResult.no(
            mode: mode,
            reasons: "Bot accepts only Bot, got #{other_type.class}"
          )
        end

        # Dynamic[T] in gradual mode is liberally inhabited; any concrete
        # other type is accepted because gradual consistency permits the
        # crossing. (Other being Dynamic was handled in {.accepts}.)
        def accepts_dynamic(_self_type, _other_type, mode)
          Type::AcceptsResult.yes(
            mode: mode,
            reasons: "gradual: Dynamic[T] accepts any concrete type"
          )
        end

        # Union[A,B].accepts(X) iff some member accepts X. Yes wins as
        # soon as we find one; otherwise we surface "maybe" only when at
        # least one member returned maybe (cannot rule out coverage),
        # else "no".
        def accepts_union_self(union, other_type, mode)
          results = union.members.map { |m| accepts(m, other_type, mode: mode) }

          if results.any?(&:yes?)
            return Type::AcceptsResult.yes(
              mode: mode,
              reasons: "union has a member that accepts"
            )
          end

          if results.any?(&:maybe?)
            Type::AcceptsResult.maybe(mode: mode, reasons: "no union member proved acceptance")
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "no union member accepts #{other_type.class}"
            )
          end
        end

        # self.accepts(Union[Y, Z]) iff self accepts every Y_i. Strict
        # AND across members: any "no" turns the whole result no, any
        # "maybe" without a "no" gives maybe, all "yes" gives yes.
        def accepts_union_other(self_type, union, mode)
          results = union.members.map { |m| accepts(self_type, m, mode: mode) }

          if results.any?(&:no?)
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "a union member is rejected"
            )
          end

          if results.any?(&:maybe?)
            Type::AcceptsResult.maybe(
              mode: mode,
              reasons: "a union member could not be proven accepted"
            )
          else
            Type::AcceptsResult.yes(mode: mode, reasons: "every union member accepted")
          end
        end

        # Singleton[C] only accepts another Singleton[D] where D is a
        # subclass of (or equal to) C. Any other carrier (instance,
        # constant, ...) is no, because the singleton type's inhabitants
        # are the class objects themselves.
        def accepts_singleton(self_type, other_type, mode)
          unless other_type.is_a?(Type::Singleton)
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "Singleton[#{self_type.class_name}] does not accept #{other_type.class}"
            )
          end

          class_subtype_result(
            target_name: self_type.class_name,
            actual_name: other_type.class_name,
            mode: mode,
            kind: :singleton
          )
        end

        # Nominal[C] accepts:
        # - Nominal[D] when D <= C (Ruby class subtype) and the
        #   `type_args` are compatible (see {#accepts_nominal_args});
        # - Constant[v] when v.is_a?(klass(C)). The type_args of self
        #   are ignored here because a Constant carries a concrete
        #   value, not a generic instantiation, and the analyzer has no
        #   way to refute the args from a literal alone.
        # - Tuple[*] when self is the Array (or a supertype) family.
        #   The Tuple is projected to `Nominal[Array, [union(elements)]]`
        #   so the existing generic-arg machinery handles it.
        # - HashShape{*} when self is the Hash (or a supertype) family,
        #   projected to `Nominal[Hash, [union(keys), union(values)]]`.
        # - Singleton: never (wrong value kind).
        def accepts_nominal(self_type, other_type, mode)
          case other_type
          when Type::Nominal
            accepts_nominal_from_nominal(self_type, other_type, mode)
          when Type::Constant
            accepts_nominal_from_constant(self_type, other_type, mode)
          when Type::Singleton
            accepts_nominal_from_singleton(self_type, other_type, mode)
          when Type::IntegerRange
            accepts_nominal_from_integer_range(self_type, other_type, mode)
          when Type::Tuple
            accepts(self_type, project_tuple_to_nominal(other_type), mode: mode)
              .with_reason("projected Tuple to Nominal[Array]")
          when Type::HashShape
            accepts(self_type, project_hash_shape_to_nominal(other_type), mode: mode)
              .with_reason("projected HashShape to Nominal[Hash]")
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "Nominal[#{self_type.class_name}] rejects #{other_type.class}"
            )
          end
        end

        # `Nominal[Integer]` (and anything Integer is-a, like Numeric) accepts
        # any `IntegerRange`; nothing else does. Argument-bearing `Nominal`s
        # never accept `IntegerRange` because IntegerRange has no type args.
        INTEGER_NOMINAL_ANCESTORS = %w[Integer Numeric Comparable Object BasicObject].freeze
        private_constant :INTEGER_NOMINAL_ANCESTORS

        def accepts_nominal_from_integer_range(self_type, _other_type, mode)
          unless self_type.type_args.empty?
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "Nominal[#{self_type.class_name}] with type args rejects IntegerRange"
            )
          end

          if INTEGER_NOMINAL_ANCESTORS.include?(self_type.class_name)
            Type::AcceptsResult.yes(
              mode: mode,
              reasons: "IntegerRange is-a #{self_type.class_name}"
            )
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "Nominal[#{self_type.class_name}] rejects IntegerRange"
            )
          end
        end

        # v0.0.2 — meta-type rule. A `Singleton[T]` is the
        # class object for `T`, so it is an instance of
        # `Class` (when `T` is a class) and always an instance
        # of `Module`. Without this rule a method whose
        # parameter is typed `Class | Module` would reject
        # every `is_a?(SomeClass)` call and similar
        # introspection patterns. The rule conservatively
        # answers `:yes` for `Module` (every singleton is at
        # least a Module) and for `Class` / `Object` /
        # `BasicObject` (the class object inherits from
        # those). Other Nominals fall through to the default
        # `:no`.
        META_NOMINALS_FROM_SINGLETON = %w[Module Class Object BasicObject].freeze
        private_constant :META_NOMINALS_FROM_SINGLETON

        def accepts_nominal_from_singleton(self_type, other_type, mode)
          if META_NOMINALS_FROM_SINGLETON.include?(self_type.class_name)
            return Type::AcceptsResult.yes(
              mode: mode,
              reasons: "Singleton[#{other_type.class_name}] is-a #{self_type.class_name}"
            )
          end

          Type::AcceptsResult.no(
            mode: mode,
            reasons: "Nominal[#{self_type.class_name}] rejects Singleton[#{other_type.class_name}]"
          )
        end

        def accepts_nominal_from_nominal(self_type, other_type, mode)
          class_result = class_subtype_result(
            target_name: self_type.class_name,
            actual_name: other_type.class_name,
            mode: mode,
            kind: :instance
          )
          return class_result if class_result.no?

          args_result = accepts_nominal_args(self_type, other_type, mode)
          combine_results(class_result, args_result, mode)
        end

        def project_tuple_to_nominal(tuple)
          if tuple.elements.empty?
            Type::Combinator.nominal_of(Array)
          else
            Type::Combinator.nominal_of(
              Array,
              type_args: [Type::Combinator.union(*tuple.elements)]
            )
          end
        end

        def project_hash_shape_to_nominal(shape)
          return Type::Combinator.nominal_of(Hash) if shape.pairs.empty?

          key_types = shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) }
          value_types = shape.pairs.values
          Type::Combinator.nominal_of(
            Hash,
            type_args: [
              Type::Combinator.union(*key_types),
              Type::Combinator.union(*value_types)
            ]
          )
        end

        # Slice 4 phase 2d generic acceptance. Type arguments are
        # treated covariantly element-wise (gradual default; declared
        # variance lands in Slice 5+). When either side has no
        # type_args we are lenient: the absent side is the "raw" form
        # that historically meant "any instantiation", so we keep
        # backward compatibility for call sites that have not yet
        # learned to carry generics.
        def accepts_nominal_args(self_type, other_type, mode)
          shortcut = nominal_args_shortcut(self_type, other_type, mode)
          return shortcut if shortcut

          per_arg = self_type.type_args.zip(other_type.type_args).map do |formal, actual|
            accepts(formal, actual, mode: mode)
          end
          combine_arg_results(per_arg, mode)
        end

        # Returns an `AcceptsResult` for the universal short-circuits
        # (raw self, raw other, arity mismatch) or `nil` when the full
        # element-wise check still has to run.
        def nominal_args_shortcut(self_type, other_type, mode)
          return Type::AcceptsResult.yes(mode: mode, reasons: "self has no type_args") if self_type.type_args.empty?
          if other_type.type_args.empty?
            return Type::AcceptsResult.maybe(
              mode: mode,
              reasons: "other has no type_args; assuming compatible (raw)"
            )
          end

          return nil if self_type.type_args.size == other_type.type_args.size

          Type::AcceptsResult.no(
            mode: mode,
            reasons: "type_args arity mismatch: #{self_type.type_args.size} vs #{other_type.type_args.size}"
          )
        end

        def combine_arg_results(per_arg, mode)
          if per_arg.any?(&:no?)
            return Type::AcceptsResult.no(mode: mode, reasons: "a type_arg is rejected (covariant)")
          end

          if per_arg.any?(&:maybe?)
            Type::AcceptsResult.maybe(mode: mode, reasons: "a type_arg could not be proven accepted")
          else
            Type::AcceptsResult.yes(mode: mode, reasons: "every type_arg accepted (covariant)")
          end
        end

        def combine_results(class_result, args_result, mode)
          combined_trinary = class_result.trinary.and(args_result.trinary)
          Type::AcceptsResult.new(combined_trinary, mode: mode, reasons: class_result.reasons + args_result.reasons)
        end

        def accepts_nominal_from_constant(self_type, constant, mode)
          ruby_class = resolve_class(self_type.class_name)
          if ruby_class.nil?
            return Type::AcceptsResult.maybe(
              mode: mode,
              reasons: "class #{self_type.class_name} not loadable; cannot prove from Constant"
            )
          end

          if constant.value.is_a?(ruby_class)
            Type::AcceptsResult.yes(mode: mode, reasons: "Constant value is_a?(#{self_type.class_name})")
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "Constant value is not a #{self_type.class_name}"
            )
          end
        end

        # IntegerRange[a..b] accepts:
        # - Constant[n] where n is an Integer covered by [a..b];
        # - IntegerRange[c..d] where [c..d] ⊆ [a..b];
        # - Nominal[Integer] only when self is the universal range
        #   (`int<min, max>`), since otherwise an arbitrary Integer
        #   could fall outside the bound.
        # Anything else is rejected.
        def accepts_integer_range(self_type, other_type, mode)
          case other_type
          when Type::Constant
            accepts_integer_range_from_constant(self_type, other_type, mode)
          when Type::IntegerRange
            accepts_integer_range_from_integer_range(self_type, other_type, mode)
          when Type::Nominal
            accepts_integer_range_from_nominal(self_type, other_type, mode)
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "IntegerRange rejects #{other_type.class}"
            )
          end
        end

        def accepts_integer_range_from_constant(self_type, constant, mode)
          unless constant.value.is_a?(Integer)
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "IntegerRange rejects non-Integer Constant"
            )
          end

          if self_type.covers?(constant.value)
            Type::AcceptsResult.yes(
              mode: mode,
              reasons: "Constant[#{constant.value}] is in #{self_type.describe}"
            )
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "Constant[#{constant.value}] outside #{self_type.describe}"
            )
          end
        end

        def accepts_integer_range_from_integer_range(self_type, other_range, mode)
          if self_type.lower <= other_range.lower && other_range.upper <= self_type.upper
            Type::AcceptsResult.yes(
              mode: mode,
              reasons: "#{other_range.describe} ⊆ #{self_type.describe}"
            )
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "#{other_range.describe} not contained in #{self_type.describe}"
            )
          end
        end

        def accepts_integer_range_from_nominal(self_type, nominal, mode)
          unless nominal.class_name == "Integer"
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "IntegerRange rejects Nominal[#{nominal.class_name}]"
            )
          end

          if self_type.universal?
            Type::AcceptsResult.yes(
              mode: mode,
              reasons: "universal IntegerRange accepts Nominal[Integer]"
            )
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "non-universal IntegerRange rejects Nominal[Integer] (could fall outside #{self_type.describe})"
            )
          end
        end

        # `Difference[base, removed]` accepts another type X when
        # the base accepts X *and* X's value set is provably
        # disjoint from `removed`. The disjointness test is the
        # subtle part — it is NOT the same as `removed.accepts(X)`,
        # because `Nominal[String]` includes `""` even though
        # `Constant[""]` does not "accept" `Nominal[String]`.
        # The conservative rule here: we can prove disjointness
        # only when X is itself a `Constant` carrier (compare
        # values directly) or another `Difference` with the same
        # removed value (already exhibits the disjointness). Any
        # other shape — Nominal, Union, IntegerRange — could
        # overlap the removed value, so the difference rejects
        # it under gradual mode.
        def accepts_difference(self_type, other_type, mode)
          base_result = accepts(self_type.base, other_type, mode: mode)
          return base_result if base_result.no?

          unless provably_disjoint_from_removed?(other_type, self_type.removed)
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "#{self_type.describe} cannot prove #{other_type.class} excludes the removed value"
            )
          end

          base_result.with_reason("#{self_type.describe}: base accepts and removed is disjoint")
        end

        def provably_disjoint_from_removed?(other_type, removed)
          case other_type
          when Type::Constant
            !(removed.is_a?(Type::Constant) && removed.value == other_type.value)
          when Type::Difference
            # `Difference[A, removed_R].accepts(Difference[B, R])` —
            # the inner difference exhibits the same disjointness;
            # forward to the base.
            other_type.removed == removed && provably_disjoint_from_removed?(other_type.base, removed)
          end
        end

        # `Refined[base, predicate]` accepts another type X when
        # the base accepts the *base* of X *and* X is provably
        # contained in the predicate's value set. The base
        # check is delegated to `accepts(self.base, X.base)`
        # so handlers like `accepts_nominal` see Nominal-vs-
        # Nominal and return their normal answer (the inner
        # `accepts_nominal` does not register `Refined` /
        # `Difference` as direct other-shapes — projecting to
        # the base is what makes the comparison meaningful).
        #
        # Provability rules in gradual mode (the conservative
        # analogue of `accepts_difference`):
        #
        # - X is a `Refined` with the *same* predicate_id —
        #   exact predicate match, accept.
        # - X is a `Constant` whose value the predicate's
        #   recogniser accepts — the value is statically
        #   contained, accept. A recognised non-match is `:no`.
        # - Anything else (Nominal, Union, IntegerRange,
        #   Difference) — predicate-subset cannot be proven
        #   without a runtime test, so reject under gradual
        #   mode rather than degrade to `:maybe`. Mirrors the
        #   `accepts_difference` policy.
        def accepts_refined(self_type, other_type, mode)
          case other_type
          when Type::Refined then accepts_refined_from_refined(self_type, other_type, mode)
          when Type::Constant then accepts_refined_from_constant(self_type, other_type, mode)
          else accepts_refined_other_shape(self_type, other_type, mode)
          end
        end

        def accepts_refined_from_refined(self_type, other_type, mode)
          base_result = accepts(self_type.base, other_type.base, mode: mode)
          return base_result if base_result.no?

          if other_type.predicate_id == self_type.predicate_id
            base_result.with_reason("matching predicate :#{self_type.predicate_id}")
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "predicate mismatch: :#{self_type.predicate_id} vs :#{other_type.predicate_id}"
            )
          end
        end

        def accepts_refined_from_constant(self_type, constant, mode)
          base_result = accepts(self_type.base, constant, mode: mode)
          return base_result if base_result.no?

          case self_type.matches?(constant.value)
          when true
            base_result.with_reason("Constant value satisfies :#{self_type.predicate_id}")
          when false
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "Constant value fails :#{self_type.predicate_id}"
            )
          else
            Type::AcceptsResult.maybe(
              mode: mode,
              reasons: "predicate :#{self_type.predicate_id} not in registry"
            )
          end
        end

        def accepts_refined_other_shape(self_type, other_type, mode)
          base_result = accepts(self_type.base, other_type, mode: mode)
          return base_result if base_result.no?

          Type::AcceptsResult.no(
            mode: mode,
            reasons: "#{self_type.describe} cannot prove #{other_type.class} satisfies " \
                     ":#{self_type.predicate_id}"
          )
        end

        # Constant[v] accepts only Constant[v'] with structurally equal
        # value. Any other type is rejected (modulo the universal
        # Bot/Dynamic short-circuits already applied upstream).
        def accepts_constant(self_type, other_type, mode)
          if other_type.is_a?(Type::Constant) && self_type == other_type
            Type::AcceptsResult.yes(mode: mode, reasons: "structural literal match")
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "Constant[#{self_type.value.inspect}] rejects #{other_type.class}"
            )
          end
        end

        # Tuple[A1..An] accepts:
        # - Tuple[B1..Bn] when arities match and each Ai accepts Bi
        #   (covariant per-position).
        # - Anything else: no (we cannot prove the arity from a generic
        #   nominal alone).
        def accepts_tuple(self_type, other_type, mode)
          unless other_type.is_a?(Type::Tuple)
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "Tuple does not accept #{other_type.class}"
            )
          end

          if self_type.elements.size != other_type.elements.size
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "tuple arity mismatch: #{self_type.elements.size} vs #{other_type.elements.size}"
            )
          end

          per_element = self_type.elements.zip(other_type.elements).map do |formal, actual|
            accepts(formal, actual, mode: mode)
          end
          combine_arg_results(per_element, mode)
        end

        # HashShape{k1: T1, ...} accepts another HashShape when every
        # required key of self is required on the other side and Ti
        # accepts Ui (depth covariant). Optional keys may be absent on
        # the other side; when present, their values are checked. A
        # closed self rejects known or possible extra keys. Other
        # types are rejected; the converse direction (a Nominal
        # accepting a HashShape) is handled by `accepts_nominal` via
        # projection.
        def accepts_hash_shape(self_type, other_type, mode)
          unless other_type.is_a?(Type::HashShape)
            return Type::AcceptsResult.no(
              mode: mode,
              reasons: "HashShape does not accept #{other_type.class}"
            )
          end

          missing = self_type.required_keys.reject { |key| other_type.required_key?(key) }
          return hash_shape_no(mode, "HashShape missing required keys: #{missing.inspect}") unless missing.empty?

          if self_type.closed?
            return hash_shape_no(mode, "HashShape closed target rejects open source") if other_type.open?

            extra = other_type.pairs.keys - self_type.pairs.keys
            unless extra.empty?
              return hash_shape_no(mode, "HashShape closed target rejects extra keys: #{extra.inspect}")
            end
          end

          per_entry = hash_shape_entry_results(self_type, other_type, mode)
          combine_arg_results(per_entry, mode)
        end

        def hash_shape_entry_results(self_type, other_type, mode)
          self_type.pairs.filter_map do |key, formal|
            next unless other_type.pairs.key?(key)

            accepts(formal, other_type.pairs.fetch(key), mode: mode)
          end
        end

        def hash_shape_no(mode, reason)
          Type::AcceptsResult.no(mode: mode, reasons: reason)
        end

        # Slice 4 phase 2c uses Ruby's actual class hierarchy to answer
        # "is D a subclass of C?". This works for any class loadable
        # through Object.const_get -- core, stdlib, and live application
        # classes. When either name fails to resolve we surface "maybe":
        # the caller (overload selector) treats yes/maybe identically,
        # so the conservative answer keeps overload coverage intact.
        # Slice 5 will replace this with an RBS-driven hierarchy lookup
        # so ahead-of-time type checking no longer relies on Ruby
        # loading the application classes.
        def class_subtype_result(target_name:, actual_name:, mode:, kind:)
          return Type::AcceptsResult.yes(mode: mode, reasons: "exact name match") if target_name == actual_name

          target_class = resolve_class(target_name)
          actual_class = resolve_class(actual_name)
          if target_class.nil? || actual_class.nil?
            return Type::AcceptsResult.maybe(
              mode: mode,
              reasons: "subtype check unresolved (#{kind}: #{actual_name} <= #{target_name})"
            )
          end

          if actual_class <= target_class
            Type::AcceptsResult.yes(
              mode: mode,
              reasons: "#{actual_name} <= #{target_name} via Ruby hierarchy"
            )
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "#{actual_name} is not a subclass of #{target_name}"
            )
          end
        end

        def resolve_class(name)
          Object.const_get(name)
        rescue NameError
          nil
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
