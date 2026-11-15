# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #3242 — whether a receiver's `find` / `detect` / `find_index` / `count` / `all?` / `any?` / `none?`
      # may be other than core's. {BlockFolding}'s constant-block folds for those methods read no receiver shape, so
      # they answer core's semantics, and they are sound only on a carrier known to be a core collection or
      # enumerable. Anything else may define the method itself: a project class (`class Bag; def find = (yield; 8);
      # end`), a subclass of a core class (its own `Nominal`), a class object (`def self.find`), a `Data.define` or
      # `Struct.new` class, or a scalar that has no such method at all.
      module CoreEnumerableReceiver
        module_function

        # The nominal receivers whose methods above are core's: Array's, Hash's, Set's, Range's own, or
        # Enumerable's. `RBS::Unnamed::ENVClass` is `ENV`, which extends Enumerable.
        NOMINALS = Ractor.make_shareable(
          Set[
            "Array", "Hash", "Set", "Range", "Enumerable", "Enumerator", "Enumerator::Lazy",
            "Enumerator::ArithmeticSequence", "Enumerator::Chain", "Enumerator::Product", "Dir",
            "RBS::Unnamed::ENVClass"
          ].freeze
        )

        # False only for a carrier known to be a core collection or enumerable: a `Tuple` / `HashShape` literal
        # shape, a `Constant` `Range` or `Set`, a `Nominal` in {NOMINALS}, `Top`, and a `Dynamic` / `Difference` /
        # `Refined` / `Union` / `Intersection` over those. Every other receiver is true, so the folds decline.
        def project_receiver?(receiver)
          case receiver
          when Type::Tuple, Type::HashShape, Type::Top then false
          when Type::Constant then !(receiver.value.is_a?(Range) || receiver.value.is_a?(::Set))
          when Type::Nominal then !NOMINALS.include?(receiver.class_name)
          when Type::Difference, Type::Refined then project_receiver?(receiver.base)
          when Type::Union, Type::Intersection then receiver.members.any? { |member| project_receiver?(member) }
          when Type::Dynamic then project_receiver?(receiver.static_facet)
          else true
          end
        end
      end
    end
  end
end
