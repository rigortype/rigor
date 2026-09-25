# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../source/node_children"
require_relative "../type"
require_relative "block_call_timing"

module Rigor
  module Inference
    # Issue #1360 — `$!`, the exception being rescued, and `$@`, its backtrace. Ruby does not keep them in the method
    # frame's special-variable slot, as it keeps `$~` and `$_`: a read of `$!` walks the running execution context's
    # frames to the nearest rescue frame. So:
    #
    # - inside a `rescue` clause, and inside a rescue modifier's fallback, `$!` is the exception that clause rescued,
    #   in every block the clause runs and every method it calls;
    # - once the `begin` or the modifier exits, however it exits, `$!` is what it was before it started: `nil` at the
    #   top of a method called from nowhere special, the outer exception after a nested `begin` in a rescue clause;
    # - an `else` clause and the body read that earlier value too, and an `ensure` clause reads it when the body or a
    #   rescue clause finished, but the exception in flight when one raised.
    #
    # A method body cannot know what its caller is rescuing, so it starts unbound; a thread's or fiber's root block
    # runs in an execution context of its own, where `$!` is `nil` ({FreshFrameBlocks.entry}); and a closure's body
    # runs whenever it is called, usually after the clause it is written in exited ({FreshFrameBlocks.closure_entry}).
    module ErrorInfo
      ERROR_INFO = :$!
      BACKTRACE = :$@
      NAMES = [ERROR_INFO, BACKTRACE].freeze
      EXCEPTION_ORDERINGS = Set[:equal, :subclass].freeze
      private_constant :ERROR_INFO, :BACKTRACE, :NAMES, :EXCEPTION_ORDERINGS

      module_function

      # The scope a `rescue` clause, or a rescue modifier's fallback, runs from: `$!` bound to the exception it rescued
      # and `$@` to that exception's backtrace. `exception_type` is what `rescue … => e` binds `e` to
      # (`StatementEvaluator#rescue_exception_type`): the union of the named classes' instances, `StandardError` for a
      # bare `rescue`. A member that is not a class RBS or the program places below `Exception` reads `Dynamic[top]`
      # instead: a rescue list may name a module with its own `===` (`rescue NetworkErrors`), which matches exceptions
      # that are not instances of it, and a class the analyzer cannot place may be such an object too.
      #
      # `$@` calls the exception's `backtrace`, which is an `Array[String]` for a raised exception; a program that
      # defines a method named `backtrace` anywhere may return anything from it, so `$@` is left unbound there.
      def rescue_entry(scope, exception_type)
        entered = scope.forget_error_info.with_global(ERROR_INFO, rescued_type(exception_type, scope))
        return entered if BlockCallTiming.project_defines_anywhere?(:backtrace, scope)

        entered.with_global(BACKTRACE, backtrace_type)
      end

      # The scope a rescue modifier's fallback (`expr rescue fallback`) runs from, which rescues a `StandardError`.
      def modifier_entry(scope)
        rescue_entry(scope, Type::Combinator.nominal_of("StandardError"))
      end

      # True when `node` reads `$!` or `$@` anywhere in it: the gate on typing a rescue modifier's fallback under
      # {.modifier_entry}, which most fallbacks (`rescue nil`) never need.
      def read_in?(node)
        return false unless node.is_a?(Prism::Node)
        return NAMES.include?(node.name) if node.is_a?(Prism::GlobalVariableReadNode)

        found = false
        node.rigor_each_child { |child| found ||= read_in?(child) }
        found
      end

      # `scope` with `$!` and `$@` as `entry` binds them, and unbound where `entry` leaves them unbound: the scope past
      # a `begin` or a rescue modifier that started from `entry`, whichever way it left.
      def restore(scope, entry)
        return scope if NAMES.all? { |name| scope.global(name).equal?(entry.global(name)) }

        NAMES.reduce(scope.forget_error_info) do |acc, name|
          bound = entry.global(name)
          bound ? acc.with_global(name, bound) : acc
        end
      end

      def rescued_type(exception_type, scope)
        members = exception_type.is_a?(Type::Union) ? exception_type.members : [exception_type]
        return exception_type if members.all? { |member| exception_instance?(member, scope) }

        Type::Combinator.union(
          *members.map { |member| exception_instance?(member, scope) ? member : Type::Combinator.untyped }
        )
      end

      # True when `type` is an instance of a class below `Exception`: one RBS places there, or a project class whose
      # superclass chain reaches one (`class MyError < StandardError`), which the RBS environment does not know.
      def exception_instance?(type, scope)
        return false unless type.is_a?(Type::Nominal)

        class_name = type.class_name
        return true if exception_class?(class_name, scope)
        return false unless scope.known_user_class?(class_name)

        scope.external_ancestor_name_candidates(class_name, mixins: false).any? do |candidates|
          known = candidates.find { |candidate| Reflection.rbs_class_known?(candidate, scope: scope) }
          !known.nil? && exception_class?(known, scope)
        end
      rescue StandardError
        false
      end

      def exception_class?(class_name, scope)
        EXCEPTION_ORDERINGS.include?(scope.environment.class_ordering(class_name, "Exception"))
      end

      def backtrace_type
        Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.nominal_of("String")])
      end
      private_class_method :rescued_type, :exception_instance?, :exception_class?, :backtrace_type
    end
  end
end
