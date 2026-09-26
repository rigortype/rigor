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
      # The globals a rescue modifier's fallback reads differently from the modifier's entry ({.modifier_entry}).
      MODIFIER_NAMES = [ERROR_INFO, BACKTRACE, :$?].freeze
      EXCEPTION_ORDERINGS = Set[:equal, :subclass].freeze
      DEFINERS = Set[:define_method, :define_singleton_method].freeze
      # The class guards a clause may put on `$!` ({.guarded?}).
      GUARDS = Set[:is_a?, :kind_of?, :instance_of?, :respond_to?].freeze
      private_constant :ERROR_INFO, :BACKTRACE, :NAMES, :MODIFIER_NAMES, :EXCEPTION_ORDERINGS, :GUARDS, :DEFINERS

      module_function

      # The scope a `rescue` clause, or a rescue modifier's fallback, runs from: `$!` bound to the exception it rescued
      # and `$@` to that exception's backtrace, with `$?` unbound. `exception_type` is what `rescue … => e` binds `e` to
      # (`StatementEvaluator#rescue_exception_type`): the union of the named classes' instances, `StandardError` for a
      # bare `rescue`. A member that is not a class RBS or the program places below `Exception` reads `Dynamic[top]`
      # instead: a rescue list may name a module with its own `===` (`rescue NetworkErrors`), which matches exceptions
      # that are not instances of it, and a class the analyzer cannot place may be such an object too. So does a class
      # that it or a project ancestor gives its own singleton `===` (`class Matchy < StandardError; def self.===(o) =
      # true`).
      #
      # `body` is the clause's statements or the fallback, and `reference` the name of the local a `rescue … => e`
      # clause binds. When the body guards `$!`, or that local, which is the same object, by its class ({.guarded?}),
      # the clause reads `$!` and `$@` unbound, as it did before issue #1360: `$!.key if e.is_a?(KeyError)` would report
      # the bound `StandardError` against the guard (ADR-117, point 3), since narrowing `e` does not narrow `$!`. #1429
      # made a class guard on `$!` itself narrow it; #1447 narrows this decline to the guards that still do not.
      #
      # `$@` calls the exception's `backtrace`, which is an `Array[String]` for a raised exception. It is left unbound
      # in a program that defines a method named `backtrace` anywhere, which may return anything, and in a clause
      # whose body calls `set_backtrace`, which may set it to nil.
      #
      # `$?` is unbound because the exception may have been raised while a subprocess waited: a backtick, `%x` or
      # `system` sets `$?` to nil before it runs the child, so a `Timeout::Error`, an `Interrupt` or a `Thread#raise`
      # there leaves it nil.
      def rescue_entry(scope, exception_type, body = nil, reference = nil)
        entered = scope.forget_error_info.forget_last_status
        # Narrowed to the guards #1429 does not narrow in #1447.
        return entered if guarded?(body, reference)

        entered = entered.with_global(ERROR_INFO, rescued_type(exception_type, scope))
        return entered if calls_set_backtrace?(body) || BlockCallTiming.project_defines_anywhere?(:backtrace, scope)

        entered.with_global(BACKTRACE, backtrace_type)
      end

      # The scope a rescue modifier's fallback (`expr rescue fallback`) runs from, which rescues a `StandardError`.
      def modifier_entry(scope, fallback = nil)
        rescue_entry(scope, Type::Combinator.nominal_of("StandardError"), fallback)
      end

      # The class guards on `$!` that {.rescue_entry} declines on, anywhere in `node`: `$!.is_a?`, `kind_of?`,
      # `instance_of?` or `respond_to?`, a `===` whose argument is `$!` (`KeyError === $!`), and `case $!`, and the
      # same on a read of the local named `reference`.
      def guarded?(node, reference = nil)
        return false unless node.is_a?(Prism::Node)
        return true if guard?(node, reference)

        found = false
        node.rigor_each_child { |child| found ||= guarded?(child, reference) }
        found
      end

      def guard?(node, reference)
        case node
        when Prism::CallNode
          (GUARDS.include?(node.name) && error_info_read?(node.receiver, reference)) ||
            (node.name == :=== && error_info_read?(node.arguments&.arguments&.first, reference))
        when Prism::CaseNode, Prism::CaseMatchNode then error_info_read?(node.predicate, reference)
        else false
        end
      end

      def error_info_read?(node, reference)
        case node
        when Prism::GlobalVariableReadNode then node.name == ERROR_INFO
        when Prism::LocalVariableReadNode then !reference.nil? && node.name == reference
        else false
        end
      end

      # True when `node` calls `set_backtrace` anywhere, on any receiver: `$!.set_backtrace(nil)` makes `$@` nil.
      def calls_set_backtrace?(node)
        return false unless node.is_a?(Prism::Node)
        return true if node.is_a?(Prism::CallNode) && node.name == :set_backtrace

        found = false
        node.rigor_each_child { |child| found ||= calls_set_backtrace?(child) }
        found
      end
      private_class_method :guard?, :error_info_read?, :calls_set_backtrace?

      # True when `node` reads `$!`, `$@` or `$?` anywhere in it: the gate on typing a rescue modifier's fallback
      # under {.modifier_entry}, which most fallbacks (`rescue nil`) never need.
      def read_in?(node)
        return false unless node.is_a?(Prism::Node)
        return MODIFIER_NAMES.include?(node.name) if node.is_a?(Prism::GlobalVariableReadNode)

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
        return false if own_case_equality?(class_name, scope)
        return true if exception_class?(class_name, scope)
        return false unless scope.known_user_class?(class_name)

        scope.external_ancestor_name_candidates(class_name, mixins: false).any? do |candidates|
          known = candidates.find { |candidate| Reflection.rbs_class_known?(candidate, scope: scope) }
          !known.nil? && exception_class?(known, scope)
        end
      rescue StandardError
        false
      end

      # True when the program gives `class_name`, or a project ancestor of it, a singleton `===`, which `rescue` calls
      # to match and which may accept an exception that is not an instance of it: a `def self.===` or `class << self`
      # `def ===`, or, anywhere in the file being read, a `define_method` or `define_singleton_method` naming `===`
      # ({.defines_case_equality?}), which the discovery tables do not place on a class, so it counts for every class.
      def own_case_equality?(class_name, scope)
        scope.discovery.defines_case_equality ||
          !scope.singleton_def_through_ancestors(class_name, :===).first.nil?
      end

      # True when `node` is a `define_method` or `define_singleton_method` call whose literal name is `===`.
      # `Inference::ScopeIndexer` records whether a file holds one ({Scope::DiscoveryIndex#defines_case_equality}).
      def defines_case_equality?(node)
        return false unless node.is_a?(Prism::CallNode) && DEFINERS.include?(node.name)

        name = node.arguments&.arguments&.first
        (name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)) && name.unescaped == "==="
      end

      def exception_class?(class_name, scope)
        EXCEPTION_ORDERINGS.include?(scope.environment.class_ordering(class_name, "Exception"))
      end

      def backtrace_type
        Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.nominal_of("String")])
      end
      private_class_method :rescued_type, :exception_instance?, :own_case_equality?, :exception_class?, :backtrace_type
    end
  end
end
