# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../type"
require_relative "argument_nodes"
require_relative "overload_selector"
require_relative "rbs_dispatch"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #2884 — `X.new` through a `def self.new` that a project, gem or collection signature declares on `X` or
      # on an ancestor of `X`. RBS models a constructor that answers another class this way (`email_address` declares
      # `def self.new: (...) -> Address` on `EmailAddress`), and `MethodDispatcher#meta_new` answered `Nominal[X]` for
      # every `Singleton[X].new` before any RBS tier ran. `meta_new` asks this module only after its curated lifts
      # (`Array`, `Set`, `Hash`, `Struct`, `Class.new`, …) have declined, and keeps its `Nominal[X]` answer whenever
      # this one is nil.
      #
      # The declaration counts only when it is an explicit `def self.new` (not the `new` RBS builds from `initialize`),
      # every one of its definitions sits outside the `rbs` gem's core and stdlib trees
      # ({Environment::RbsLoader#declared_outside_core_stdlib?}), and the class carrying it is not one core or stdlib
      # declares. Core declares `Data.new: () -> bot` and `Ractor.new: … -> Ractor`, stdlib `Tempfile.new`; a project
      # class inheriting one of those keeps the `Nominal` answer the curated tiers were written around.
      #
      # The declaration is found on `X`'s own RBS (which carries its RBS ancestors' singleton methods), or, for a
      # Ruby-source class with no RBS of its own, on the first RBS-known class of its singleton
      # {Scope::ResolutionChain}. A project entry ahead of it that defines `new` ends the walk with no answer: that
      # method is the one Ruby runs. `instance` in the declared return, and a return naming the declaring class itself,
      # read the receiver class, and `self` reads its class object.
      #
      # Nil (so `Nominal[X]`) when no overload takes the arguments (argument checking of `.new` is not this tier's
      # job), and when the return translates to an untyped, `top` or `bot` answer, which would lose the precision
      # `Nominal[X]` already has.
      module DeclaredConstructor
        # A project entry of the singleton chain defines `new` in Ruby source, so that method is the one Ruby runs.
        DEFINED_IN_SOURCE = :defined_in_source
        private_constant :DEFINED_IN_SOURCE

        module_function

        def try_dispatch(class_name, context)
          environment = context.environment
          loader = environment&.rbs_loader
          return nil if loader.nil? || !loader.respond_to?(:declared_outside_core_stdlib?)

          definition = declared_new(class_name, environment, loader, context.scope)
          return nil if definition.nil? || !overload_matches?(definition, class_name, context)

          answer = RbsDispatch.declared_singleton_return(context, definition, class_name)
          answer = repoint_owner(answer, definition.defined_in.to_s.delete_prefix("::"), class_name)
          answer if usable?(answer)
        end

        class << self
          private

          def declared_new(class_name, environment, loader, scope)
            owner = declaring_class(class_name, environment, loader, scope)
            return nil if owner.nil?

            definition = Rigor::Reflection.singleton_method_definition(owner, :new, environment: environment)
            definition if definition && honoured?(definition, loader)
          end

          # Only an explicit `def self.new` counts: `RBS::DefinitionBuilder` also builds a singleton `new` from a
          # class's `initialize`, returning the declaring class, and a Ruby subclass inheriting that would read as its
          # parent. Every definition must sit outside core / stdlib, and so must the class that carries it: a project
          # signature reopening `String` to declare `self.new` does not change what `String.new` returns.
          def honoured?(definition, loader)
            definition.defs.all? { |type_def| explicit_singleton_new?(type_def.member) } &&
              loader.declared_outside_core_stdlib?(definition) &&
              !loader.core_or_stdlib_class?(definition.defined_in.to_s)
          end

          def explicit_singleton_new?(member)
            member.is_a?(::RBS::AST::Members::MethodDefinition) && member.name == :new && member.kind != :instance
          end

          # `class_name` itself when RBS knows it; else the first RBS-known class on its singleton
          # {Scope::ResolutionChain}, read in Ruby's order. Nil when a project entry ahead of it defines `new` (a
          # `def self.new`, or an `extend`ed module's `def new`), when the chain reaches none, and when the chain does
          # not stand (a fork or an unplaced mixin edge, where the tables cannot say which world ran).
          #
          # The walk runs only when some loaded signature declares a `new` whose answer for a subclass is not the
          # subclass itself ({Environment::RbsLoader#singleton_new_departs_from_instance?}); every other declaration
          # answers what `meta_new`'s `Nominal[X]` does, so without one the walk could change nothing. When it runs
          # it files its reads whatever it answers: a later edit that puts such a declaration on the chain changes
          # the answer, and the caller must be re-checked then.
          def declaring_class(class_name, environment, loader, scope)
            return class_name if Rigor::Reflection.rbs_class_known?(class_name, environment: environment)
            return nil if scope.nil? || !loader.singleton_new_departs_from_instance?

            chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
            found = first_new_owner(chain, scope, environment)
            verdict = chain.settle(scope, found, owner: nil) { |retro| first_new_owner(retro, scope, environment) }
            found unless found.nil? || found == DEFINED_IN_SOURCE || verdict != :chain
          end

          # The first entry on `chain` that answers `new`: an RBS-known class's name, or {DEFINED_IN_SOURCE} for a
          # project entry that defines it.
          def first_new_owner(chain, scope, environment)
            chain.search(scope) do |entry|
              if entry.external?
                # An external `extend`ed module is not a class object `new` is declared on; the walk passes it.
                next unless entry.superclass_edge

                entry.candidates.find { |name| Rigor::Reflection.rbs_class_known?(name, environment: environment) }
              elsif entry.side == :singleton && Rigor::Reflection.rbs_class_known?(entry.name, environment: environment)
                entry.name
              elsif scope.discovered_method?(entry.name, :new, entry.side)
                DEFINED_IN_SOURCE
              end
            end
          end

          # A genuine match only: the selector's first-overload fallback would answer a declaration the call does
          # not take.
          def overload_matches?(definition, class_name, context)
            args = context.args || []
            !OverloadSelector.select_declared(
              definition, args, Type::Combinator.singleton_of(class_name), Type::Combinator.nominal_of(class_name),
              {}, !context.block_type.nil?, context.environment, true,
              ArgumentNodes.keyword_hash_last?(context.call_node, args), nil, true
            ).empty?
          end

          # A return naming the declaring class itself (`def self.new: [T] (T) -> Box[T]`) is the constructor's own
          # class, so a subclass inheriting it answers the subclass, as `instance` does; generic arguments name the
          # owner's parameters and are dropped with it. A foreign return (`EmailAddress` -> `Address`) stays.
          def repoint_owner(answer, owner, class_name)
            return answer if owner == class_name

            case answer
            when Type::Nominal
              answer.class_name == owner ? Type::Combinator.nominal_of(class_name) : answer
            when Type::Union
              Type::Combinator.union(*answer.members.map { |member| repoint_owner(member, owner, class_name) })
            else answer
            end
          end

          def usable?(answer)
            !(answer.nil? || answer.is_a?(Type::Dynamic) || answer.is_a?(Type::Top) || answer.is_a?(Type::Bot))
          end
        end
      end
    end
  end
end
