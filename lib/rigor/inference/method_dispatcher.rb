# frozen_string_literal: true

require_relative "../type"
require_relative "method_dispatcher/constant_folding"
require_relative "method_dispatcher/shape_dispatch"
require_relative "method_dispatcher/rbs_dispatch"
require_relative "method_dispatcher/iterator_dispatch"
require_relative "method_dispatcher/block_folding"
require_relative "method_dispatcher/file_folding"
require_relative "method_dispatcher/kernel_dispatch"

module Rigor
  module Inference
    # Coordinates method dispatch for the inference engine.
    #
    # Given `(receiver_type, method_name, arg_types, block_type, environment)`,
    # the dispatcher returns the inferred result type or `nil` when no
    # rule matches. `nil` is a deliberately blunt "I don't know" signal:
    # callers (today only `ExpressionTyper`) own the fail-soft fallback
    # and decide whether to record a `FallbackTracer` event.
    #
    # Tiers (in order):
    #
    # 1. {ConstantFolding}: executes the Ruby operation directly when
    #    the receiver and argument are `Constant` carriers and the
    #    method is on the curated whitelist. Slice 2.
    # 2. {ShapeDispatch}: returns the precise element/value type for a
    #    curated catalogue of `Tuple`/`HashShape` element-access
    #    methods (`first`, `last`, `[]` with a static integer/key,
    #    `fetch`, `dig`, `size`/`length`/`count`). Slice 5 phase 2.
    # 3. {RbsDispatch}: looks up the receiver's class in the RBS
    #    environment carried by the scope and translates the method's
    #    return type into a Rigor::Type. Slice 4.
    #
    # `ShapeDispatch` deliberately runs *above* {RbsDispatch} so the
    # precise per-position/per-key answer wins over the projected
    # `Array#[]`/`Hash#fetch` answer; it falls through (`nil`) when
    # the call cannot be proved against the static shape, in which
    # case the projection answer from {RbsDispatch} applies.
    #
    # The dispatcher's public signature reserves space for `block_type:`
    # and ADR-2 plugin extensions (later slices), so call sites added
    # now do not have to be rewritten when those tiers arrive.
    module MethodDispatcher
      module_function

      # @param receiver_type [Rigor::Type, nil] type of the receiver expression, or
      #   `nil` for an implicit-self call.
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>] positional argument types.
      # @param block_type [Rigor::Type, nil] inferred return type of the
      #   accompanying `do ... end` / `{ ... }` block (Slice 6 phase C
      #   sub-phase 2). When non-nil, the dispatcher prefers an
      #   overload that declares a block, and binds the method's
      #   block-return type variable to `block_type` so a return type
      #   like `Array[U]` resolves to `Array[block_type]`.
      # @param environment [Rigor::Environment, nil] required for
      #   RBS-backed dispatch; when nil only constant folding can fire.
      # @return [Rigor::Type, nil] inferred result type, or `nil` for "no rule".
      def dispatch(receiver_type:, method_name:, arg_types:, block_type: nil, environment: nil)
        return nil if receiver_type.nil?

        precise = dispatch_precise_tiers(receiver_type, method_name, arg_types, block_type)
        return precise if precise

        rbs_result = RbsDispatch.try_dispatch(
          receiver: receiver_type, method_name: method_name, args: arg_types,
          environment: environment, block_type: block_type
        )
        return rbs_result if rbs_result

        # Slice 7 phase 10 — user-class ancestor fallback. When
        # the receiver is `Nominal[T]` or `Singleton[T]` for a
        # class not in the RBS environment (typically a
        # user-defined class), retry the dispatch against the
        # implicit ancestor: `Nominal[Object]` for instance
        # receivers and `Singleton[Object]` for singleton
        # receivers. This resolves Kernel intrinsics
        # (`require`, `raise`, `puts`, ...) and Module/Class
        # introspection (`attr_reader`, `private`, ...) on
        # user classes without requiring the user to author
        # their own RBS.
        try_user_class_fallback(receiver_type, method_name, arg_types, environment, block_type)
      end

      # Runs the precision tiers (constant fold, shape dispatch,
      # file-path fold, block fold) in order and returns the first
      # non-nil answer. Each tier owns its own receiver/argument
      # shape checks; a tier that does not recognise the receiver
      # returns nil so the next tier can try. The RBS tier sits
      # below this chain and is invoked by the outer `dispatch`
      # method.
      #
      # `BlockFolding` runs last among the precision tiers because
      # its rules apply only to block-taking calls, so the cheaper
      # arity-based fold tiers above it filter out the common
      # cases first. When `block_type` is nil the tier is a no-op.
      def dispatch_precise_tiers(receiver_type, method_name, arg_types, block_type = nil)
        meta_result = try_meta_introspection(receiver_type, method_name)
        return meta_result if meta_result

        ConstantFolding.try_fold(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          ShapeDispatch.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          FileFolding.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          KernelDispatch.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          BlockFolding.try_fold(
            receiver: receiver_type, method_name: method_name, args: arg_types, block_type: block_type
          )
      end

      def try_user_class_fallback(receiver_type, method_name, arg_types, environment, block_type)
        return nil if environment.nil?

        fallback_receiver = user_class_fallback_receiver(receiver_type, environment)
        return nil if fallback_receiver.nil?

        RbsDispatch.try_dispatch(
          receiver: fallback_receiver,
          method_name: method_name,
          args: arg_types,
          environment: environment,
          block_type: block_type
        )
      end

      def user_class_fallback_receiver(receiver_type, environment)
        loader = environment.rbs_loader
        return nil if loader.nil?

        case receiver_type
        when Type::Nominal
          return nil if loader.class_known?(receiver_type.class_name)

          environment.nominal_for_name("Object")
        when Type::Singleton
          return nil if loader.class_known?(receiver_type.class_name)

          environment.singleton_for_name("Class")
        end
      end

      # Slice 7 phase 8 — meta-introspection shortcuts. The
      # default `Object#class` RBS return type is `Class`, but
      # for a receiver of known nominal identity we can do
      # better: `instance_of(Foo).class` is `Singleton[Foo]`
      # (the class object itself), which downstream dispatch
      # uses to resolve `self.class.some_class_method`. The
      # same logic answers `Foo.class` as `Singleton[Class]`
      # (deliberate; calling `.class` on a class object yields
      # `Class`, the metaclass). We also special-case `is_a?`-
      # adjacent calls and the trivial `instance_of?(self)`
      # later as the rule catalogue grows; for now only `class`
      # is handled.
      def try_meta_introspection(receiver_type, method_name)
        case method_name
        when :class then meta_class(receiver_type)
        when :new then meta_new(receiver_type)
        end
      end

      def meta_class(receiver_type)
        case receiver_type
        when Type::Nominal then Type::Combinator.singleton_of(receiver_type.class_name)
        when Type::Constant then constant_metaclass(receiver_type.value)
        end
      end

      # `Singleton[Foo].new` returns `Nominal[Foo]` (a fresh
      # instance), regardless of whether Foo is in RBS. This
      # short-circuits the Class.new generic-`instance`
      # plumbing for user classes, so a discovered-class
      # `ScanAccumulator.new` types as `Nominal[ScanAccumulator]`
      # rather than `Class`.
      def meta_new(receiver_type)
        return nil unless receiver_type.is_a?(Type::Singleton)

        Type::Combinator.nominal_of(receiver_type.class_name)
      end

      CONSTANT_METACLASSES = {
        Integer => "Integer", Float => "Float", String => "String",
        Symbol => "Symbol", Range => "Range",
        TrueClass => "TrueClass", FalseClass => "FalseClass",
        NilClass => "NilClass"
      }.freeze
      private_constant :CONSTANT_METACLASSES

      def constant_metaclass(value)
        CONSTANT_METACLASSES.each do |klass, name|
          return Type::Combinator.singleton_of(name) if value.is_a?(klass)
        end
        nil
      end

      # Returns the positional block parameter types declared by the
      # receiving method's selected RBS overload, translated into
      # `Rigor::Type`. Used by the StatementEvaluator's CallNode
      # handler to bind block parameter names before evaluating the
      # block body.
      #
      # The probe is best-effort: it returns an empty array whenever
      # the receiver, environment, method definition, or selected
      # overload does not provide statically declared block parameter
      # types. Callers MUST treat the empty array as "no information";
      # the binder falls back to `Dynamic[Top]` for every parameter
      # slot in that case.
      #
      # @param receiver_type [Rigor::Type, nil]
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>]
      # @param environment [Rigor::Environment, nil]
      # @return [Array<Rigor::Type>]
      def expected_block_param_types(receiver_type:, method_name:, arg_types:, environment: nil)
        return [] if receiver_type.nil?

        iterator_result = IteratorDispatch.block_param_types(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types
        )
        return iterator_result if iterator_result

        RbsDispatch.block_param_types(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types,
          environment: environment
        )
      end
    end
  end
end
