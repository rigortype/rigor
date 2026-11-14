# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #3242 — whether a receiver's `find` / `detect` / `find_index` / `count` / `all?` / `any?` / `none?`
      # may be a project's own. {BlockFolding}'s constant-block folds for those methods read no receiver shape, so
      # they answer core's semantics; a class outside the core collections may define the method itself
      # (`class Bag; def find = (yield; 8); end`), and a subclass of a core class is its own `Nominal`.
      module CoreEnumerableReceiver
        module_function

        # The nominal receivers whose methods above are core's: Array's, Hash's, Set's, Range's own, or
        # Enumerable's.
        NOMINALS = Set["Array", "Hash", "Set", "Range", "Enumerator", "Enumerator::Lazy", "Enumerable"].freeze

        # True when the receiver is, or may be, an instance of a class outside {NOMINALS}: a `Nominal` of another
        # class, or a `Difference` / `Union` carrying one. The shape carriers (`Tuple`, `HashShape`, `Constant`)
        # and a `Dynamic` receiver are not, so their folds stand.
        def project_receiver?(receiver)
          case receiver
          when Type::Nominal then !NOMINALS.include?(receiver.class_name)
          when Type::Difference then project_receiver?(receiver.base)
          when Type::Union then receiver.members.any? { |member| project_receiver?(member) }
          else false
          end
        end
      end
    end
  end
end
