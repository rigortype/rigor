# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../type"
require_relative "../external_ancestor_resolution"
require_relative "user_method"

module Rigor
  module Inference
    module CallLadder
      # The `overriding_def` rung of the call ladder (ADR-116 WD12): a call on an instance whose class has its own
      # source `def` of the method, no declaration of its own, and an ancestor's declaration a project signature wrote,
      # answered from the own `def`'s body. `ExpressionTyper` asks it ahead of the dispatcher, in each entry
      # `CallLadder::RUNGS` gives it. {ExpressionTyper} is not required here: it requires this file, and `Scope` is
      # loaded before either.
      #
      # Two entries, and the one other function is private to the module:
      #
      # - {.try_call} is the rung, asked with the site and the walking typer.
      # - {.overriding_own_def?} is the rung's gate, which the read under a splat index (`c[*keys] += v`) asks in
      #   place of the rung: a splat leaves no positional argument types to bind to the own `def`'s body.
      #
      # The module holds no state. It reads the scope as `typer.scope` and calls back no method of the typer:
      # `CallLadder::PORT`'s `scope` is all it reads there. It hands the typer on to its gate and to the user-method
      # rung's positional entry, `CallLadder::UserMethod.infer`, which types the own `def`'s body.
      module OverridingDef
        module_function

        # ADR-110 WD1 / #856 — the receiver's own `def` outranks a declaration that only an ANCESTOR carries.
        #
        # RBS resolves through the fully built method table, so `RbsDispatch` answers a subclass call with a
        # signature written about the base. redmine's `FieldFormat::Base#target_class` honestly declares
        # `-> nil`; `RecordList` overrides it with a real lookup, and every call on a `RecordList` receiver
        # typed as `nil` and fired `undefined method ... for nil` on the subclass's own working code (#744).
        # A signature is authoritative for a receiver only where someone wrote it about that receiver;
        # reaching it through an ancestor is a lookup convenience, not an act of authorship.
        #
        # This is {CallLadder::TopLevelDef.try_call}'s shape one level up — there the enclosing class shadows a
        # top-level `def`, here the receiver's class shadows an ancestor's declaration — and it answers the
        # same way: re-type the override's body, and when that is not possible answer `Dynamic[Top]` rather
        # than let the inherited declaration speak for a method it does not describe.
        #
        # Three conditions, and the third is the blast radius. Clause A of the ADR (an own source `def`, no
        # own declaration) does NOT by itself stay clear of [ADR-43]: `class Foo; def each; end` inheriting
        # `Enumerable#each` satisfies it, and disqualifying bundled declarations that way is the blanket fix
        # ADR-43 rejected — the same reason {CallLadder::TopLevelDef}'s singleton RBS arm is own-class only. So the
        # ancestor whose declaration is being disqualified must itself be PROJECT-declared: a project sidecar
        # describes the source under analysis, while a bundled signature describes a class the project does
        # not own, where a project `def` is a monkey-patch and [ADR-17] owns the question.
        # `project_declared_class?` fail-softs to false, so an unattributable environment changes nothing.
        #
        # The rung, asked with the call `site` describes. The method name is the site's, not the call node's: the read
        # of `c[k] += v` is a site whose node is the write and whose name is `[]`. The body is typed with no block
        # type, as it was in the typer.
        def try_call(site, typer)
          node = site.call_node
          receiver = site.receiver
          arg_types = site.args
          method_name = site.method_name
          return nil unless overriding_own_def?(receiver, method_name, typer)

          CallLadder::UserMethod.infer(receiver, node, arg_types, method_name, nil, typer) || Type::Combinator.untyped
        end

        # The three conditions above: an own source `def` of `method_name` on the receiver's class, which has no
        # declaration of its own but inherits one a project-declared ancestor wrote.
        def overriding_own_def?(receiver, method_name, typer)
          return false unless CallLadder::UserMethod.user_inference_receiver?(receiver)

          class_name = receiver.class_name
          return false if class_name.nil?
          # `Scope#user_def_for`, not `discovered_method?`: the cross-file table deliberately withholds a
          # plain instance `def` under the ADR-17 monkey-patch contract, and this gate must see one.
          return false if typer.scope.user_def_for(class_name, method_name).nil?

          definition = ExternalAncestorResolution.method_definition(class_name, method_name, :instance,
                                                                    scope: typer.scope)
          return false if definition.nil?
          return false if ExternalAncestorResolution.declared_on_class?(definition, class_name)

          project_declared_owner?(definition, typer.scope)
        end

        # Whether the class an inherited declaration was written about is one the project declares itself.
        def project_declared_owner?(definition, scope)
          defined_in = definition.defined_in
          return false if defined_in.nil?

          Rigor::Reflection.project_declared_class?(defined_in.to_s, scope: scope)
        rescue StandardError
          false
        end

        private_class_method :project_declared_owner?
      end
    end
  end
end
