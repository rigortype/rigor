# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../../type"
require_relative "../diagnostic"
require_relative "receiver_predicates"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `call.raise-non-exception`: a `raise` / `fail` whose operand provably is not an
      # exception class or instance.
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`. It reads
      # {ReceiverPredicates} and calls nothing else in `CheckRules`.
      module RaiseNonException
        module_function

        # `call.raise-non-exception` — `raise x` / `fail x` where the first argument's statically-inferred
        # type is provably NOT a legal raise operand (PHPStan ThrowExprTypeRule analogue). Legal operands:
        # an Exception class object, an Exception instance, a String (raises RuntimeError), or any object
        # whose class defines `#exception` (the duck protocol `raise` consults at runtime). Anything else
        # (`raise 42`, `raise :sym`, `raise nil` — an explicit nil argument is a TypeError, unlike bare
        # `raise` which re-raises `$!`) raises TypeError at runtime.
        #
        # Conservative envelope (FP discipline):
        # - Implicit-self `raise` / `fail` only; an explicit-receiver call is a user method, not Kernel#raise.
        # - Silent when the project redefines `raise` / `fail` anywhere the call could resolve (a same-file
        #   toplevel def, an Object/Kernel monkey-patch, or a def on the enclosing class — in source or via
        #   `pre_eval:`).
        # - Only the first positional argument is checked; splat / kwargs / forwarded first args bail.
        # - Fires only on a concrete verdict: Dynamic / Top / unknown / unresolved types are silent, and a
        #   Union fires only when EVERY arm is independently illegal.
        # - A Class operand (`Type::Singleton`) is exact, so both `:disjoint` and `:superclass` orderings
        #   against Exception are provably illegal — but only when the class is RBS-known, not an ADR-26
        #   open receiver / synthesized stub, and its singleton defines no `exception` method.
        # - An instance operand's nominal class is NOT exact (a runtime subclass could define `#exception`
        #   or be an Exception), so only `:disjoint` fires, and the generic carriers (`Class` / `Module` /
        #   `Object` / `BasicObject`) plus module-typed values (any includer could be an Exception) bail.
        RAISE_METHOD_NAMES = %i[raise fail].freeze
        private_constant :RAISE_METHOD_NAMES

        # Instance types whose nominal class subsumes exception values (or class objects), so a "disjoint
        # from Exception" ordering proves nothing about the runtime value. `Object` / `BasicObject` order as
        # `:superclass` (already silent) but are listed for explicitness.
        RAISE_UNEXACT_INSTANCE_CLASSES = %w[Class Module Object BasicObject].freeze
        private_constant :RAISE_UNEXACT_INSTANCE_CLASSES

        def diagnostic(path, call_node, scope_index)
          return nil unless call_node.receiver.nil?
          return nil unless RAISE_METHOD_NAMES.include?(call_node.name)
          return nil unless call_node.block.nil?

          arg = first_positional_raise_operand(call_node)
          return nil if arg.nil?

          scope = scope_index[arg] || scope_index[call_node]
          return nil if scope.nil?
          return nil if raise_redefined_in_scope?(scope, call_node.name)

          operand_type = scope.type_of(arg)
          return nil unless raise_operand_verdict(operand_type, scope) == :illegal

          build_raise_non_exception_diagnostic(path, call_node, operand_type)
        end

        def first_positional_raise_operand(call_node)
          args = call_node.arguments&.arguments
          return nil if args.nil? || args.empty?

          first = args.first
          return nil if first.is_a?(Prism::SplatNode) || first.is_a?(Prism::KeywordHashNode) ||
                        first.is_a?(Prism::BlockArgumentNode) || first.is_a?(Prism::ForwardingArgumentsNode)

          first
        end

        # True when a project-side definition of `raise` / `fail` could shadow Kernel's at this call site:
        # a same-file toplevel def, a monkey-patch on Object / Kernel (in source or `pre_eval:`), or a def
        # on the enclosing class (instance or singleton side — implicit self dispatches to either depending
        # on context, and being silent for both is the cheap conservative answer).
        def raise_redefined_in_scope?(scope, name)
          return true if scope.top_level_def_for(name)
          return true if ReceiverPredicates.source_declared_method?(scope, "Object", name, :instance)
          return true if ReceiverPredicates.source_declared_method?(scope, "Kernel", name, :instance)

          self_type = scope.self_type
          return false unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name
          return false if class_name.nil?

          ReceiverPredicates.source_declared_method?(scope, class_name, name, :instance) ||
            ReceiverPredicates.source_declared_method?(scope, class_name, name, :singleton)
        end

        # Trinary verdict — `:legal` / `:illegal` / `:unknown`. Only `:illegal` fires; anything the engine
        # cannot prove stays `:unknown` (silent).
        def raise_operand_verdict(type, scope)
          case type
          when Type::Union
            verdicts = type.members.map { |member| raise_operand_verdict(member, scope) }
            return :illegal if verdicts.all?(:illegal)

            verdicts.all?(:legal) ? :legal : :unknown
          when Type::Singleton
            raise_class_operand_verdict(type.class_name, scope)
          else
            raise_instance_operand_verdict(type, scope)
          end
        end

        # A `Type::Singleton` names ONE exact class / module object, so an ordering that places it outside
        # Exception's ancestry (`:disjoint`, or `:superclass` — e.g. `raise Object`) is a proof, provided
        # the singleton also lacks an `exception` method (`raise Klass` calls `Klass.exception`). A module
        # constant orders `:disjoint` and fires unless its singleton defines `exception`.
        def raise_class_operand_verdict(class_name, scope)
          return :unknown if class_name.nil? || scope.environment.nil?
          return :unknown if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          return :unknown if Rigor::Reflection.discovered_class?(class_name, scope: scope)
          return :unknown unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          case Rigor::Reflection.class_ordering(class_name, "Exception", scope: scope)
          when :equal, :subclass then :legal
          when :superclass, :disjoint
            raise_duck_exception?(class_name, :singleton, scope) ? :legal : :illegal
          else
            :unknown
          end
        end

        # An instance operand: legal when its class is String-family (raises RuntimeError) or an Exception
        # descendant; illegal only when the class is fully known, exact enough (not a generic metaclass /
        # module carrier), provably disjoint from BOTH, and defines no `#exception`. `:superclass` stays
        # silent — a value typed `Object` may well BE an Exception at runtime.
        def raise_instance_operand_verdict(type, scope)
          class_name = ReceiverPredicates.concrete_class_name(type)
          return :unknown if class_name.nil? || scope.environment.nil?
          return :unknown if RAISE_UNEXACT_INSTANCE_CLASSES.include?(class_name)
          return :unknown if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          # A project-declared class's ancestry must not be proven from RBS alone: a `sig/` declaration that
          # omits the superclass (`class Conflict` for a source-side `class Conflict < StandardError`)
          # defaults to Object in the RBS env, which would read as "disjoint from Exception" for a class
          # that IS one at runtime (the rule's first self-check firing, `Plugin::FactStore::Conflict`).
          # Source-discovered classes stay silent.
          return :unknown if Rigor::Reflection.discovered_class?(class_name, scope: scope)
          return :unknown unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return :unknown if scope.environment.rbs_module?(class_name)

          string_ordering = Rigor::Reflection.class_ordering(class_name, "String", scope: scope)
          return :legal if %i[equal subclass].include?(string_ordering)

          case Rigor::Reflection.class_ordering(class_name, "Exception", scope: scope)
          when :equal, :subclass then :legal
          when :disjoint
            raise_duck_exception?(class_name, :instance, scope) ? :legal : :illegal
          else
            :unknown
          end
        end

        # Whether the class carries an `exception` method on the given side — from RBS, an in-source `def`,
        # or a `pre_eval:` patch. An unbuildable definition returns true (assume the duck) so structural
        # RBS gaps never manufacture a firing.
        def raise_duck_exception?(class_name, kind, scope)
          return true if ReceiverPredicates.source_declared_method?(scope, class_name, :exception, kind)

          definition = if kind == :singleton
                         Rigor::Reflection.singleton_definition(class_name, scope: scope)
                       else
                         Rigor::Reflection.instance_definition(class_name, scope: scope)
                       end
          return true if definition.nil?

          !definition.methods[:exception].nil?
        end

        def build_raise_non_exception_diagnostic(path, call_node, operand_type)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_RAISE_NON_EXCEPTION,
            path: path,
            message: "`#{call_node.name}' operand types as #{operand_type.describe(:short)}, which is not " \
                     "an Exception class, an Exception instance, a String, or an object defining " \
                     "`#exception' — this raises TypeError at runtime",
            severity: :error,
            method_name: call_node.name.to_s
          )
        end

        private_class_method :first_positional_raise_operand, :raise_redefined_in_scope?, :raise_operand_verdict,
                             :raise_class_operand_verdict, :raise_instance_operand_verdict, :raise_duck_exception?,
                             :build_raise_non_exception_diagnostic
      end
    end
  end
end
