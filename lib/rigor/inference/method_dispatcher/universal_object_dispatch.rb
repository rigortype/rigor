# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The last resolution tier for a `Dynamic` receiver: the handful of `BasicObject` / `Object` / `Kernel`
      # methods whose return type does not depend on who the receiver is.
      #
      # `x.nil?` is `bool` whatever `x` is. Until this tier existed it was `Dynamic[Top]`, because every
      # preceding tier needs a receiver it can name and the typer then fell through to the Dynamic-origin
      # propagation. The same held for `is_a?`, `respond_to?`, `!` and the rest of the set below — a
      # measurable share of the opaque expressions on a real codebase, closed by a fixed table rather than
      # by knowing anything about the receiver
      # (`docs/notes/20260831-self-check-type-coverage-audit.md` § Finding 2: +2.27 points of precision on this
      # repository's own `lib`, with zero new diagnostics).
      #
      # **Where it sits.** After every real tier has declined, so a receiver Rigor can name always resolves
      # through RBS first — `"".frozen?` is answered by `String`'s signature, not by this table. It only ever
      # replaces a `Dynamic[Top]` that the engine was about to produce anyway.
      #
      # **What is deliberately NOT here**, each measured rather than argued (same note):
      #
      # - `class` — `Nominal[Class]` erases the singleton. `p.class.dynamic_returns` on a plugin instance is
      #   real code in this repository; folding the receiver's class to the bare `Class` nominal produced 13
      #   `call.undefined-method` false positives on `lib` alone. An ADR-5 violation bought for +0.14 points.
      # - `==` / `!=` / `eql?` — the same failure at a much larger blast radius. `==` is the most commonly
      #   overridden method in Ruby, and an overridden one is free to return anything.
      # - `to_s` — receiver-independent in principle, but enabling it surfaces the RBS
      #   `Array#[](Range) -> Array[T]?` optional-return noise on `x.to_s.split("::")[0...-1]` (7
      #   `call.possible-nil-receiver` on `lib`). Not this tier's defect, but not this tier's to ship either:
      #   it goes in once that noise has an answer.
      # - `freeze` / `dup` / `clone` / `itself` / `tap` — receiver-independent in a different way (they
      #   return the receiver), so on a `Dynamic` receiver they gain nothing.
      module UniversalObjectDispatch
        # `bool` as the engine spells it — `Constant[true] | Constant[false]`, the union
        # `RbsTypeTranslator` folds RBS's `bool` to. Spelling it `Nominal[TrueClass] | Nominal[FalseClass]`
        # instead type-checks but is not the same value: it fails to match a `-> bool` declaration and
        # produced 17 spurious `def.return-type-mismatch` warnings when this tier was first prototyped.
        BOOL = Type::Combinator.union(
          Type::Combinator.constant_of(true),
          Type::Combinator.constant_of(false)
        ).freeze
        private_constant :BOOL

        # Selector => return type, for selectors defined on `BasicObject` / `Object` / `Kernel` whose result
        # is a function of the language, not of the receiver's class:
        #
        # - the type predicates (`nil?`, `is_a?` and its aliases, `respond_to?`, `frozen?`) and the identity
        #   comparison `equal?`, which `BasicObject` defines as object identity;
        # - `!`, which Ruby's own semantics constrain to `true` / `false`;
        # - `inspect`, whose `Object` contract is a `String` representation;
        # - `hash` and `object_id`, both `Integer` by contract — `hash` because `Hash` requires it.
        RETURN_TYPES = Ractor.make_shareable({
                                               :nil? => BOOL,
                                               :is_a? => BOOL,
                                               :kind_of? => BOOL,
                                               :instance_of? => BOOL,
                                               :respond_to? => BOOL,
                                               :equal? => BOOL,
                                               :frozen? => BOOL,
                                               :! => BOOL,
                                               :inspect => Type::Combinator.nominal_of("String"),
                                               :hash => Type::Combinator.nominal_of("Integer"),
                                               :object_id => Type::Combinator.nominal_of("Integer")
                                             })

        module_function

        # @param context [CallContext]
        # @return [Rigor::Type, nil] the receiver-independent return type, or nil to decline.
        def try_dispatch(context)
          return nil unless context.receiver.is_a?(Type::Dynamic)

          RETURN_TYPES[context.method_name]
        end
      end
    end
  end
end
