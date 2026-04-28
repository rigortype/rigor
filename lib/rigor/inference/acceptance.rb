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
    # Nominal, Singleton, Constant, and Union. Future shape carriers
    # (Tuple, HashShape, Record) will register their own routes by
    # adding entries to {TYPE_HANDLERS}.
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
        Type::Constant => :accepts_constant
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
        # - Singleton: never (wrong value kind).
        def accepts_nominal(self_type, other_type, mode)
          case other_type
          when Type::Nominal
            class_result = class_subtype_result(
              target_name: self_type.class_name,
              actual_name: other_type.class_name,
              mode: mode,
              kind: :instance
            )
            return class_result if class_result.no?

            args_result = accepts_nominal_args(self_type, other_type, mode)
            combine_results(class_result, args_result, mode)
          when Type::Constant
            accepts_nominal_from_constant(self_type, other_type, mode)
          else
            Type::AcceptsResult.no(
              mode: mode,
              reasons: "Nominal[#{self_type.class_name}] rejects #{other_type.class}"
            )
          end
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
