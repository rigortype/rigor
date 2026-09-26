# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # `Process` class-method calls that read flow state.
      #
      # `Process.last_status` answers the thread's last child status, the slot `$?` reads (both are
      # `rb_last_status_get` in CRuby's `process.c`). `data/core_overlay/process.rbs` declares it
      # `() -> Process::Status?`, which is right where nothing is known. But past a statement that certainly
      # ran a subprocess the flow engine has already bound `$?` to a non-nil `Process::Status`
      # ({Inference::LastStatus}); answering the declared return there would put back the possible nil
      # receiver the binding exists to remove as soon as the code reaches the status through the method
      # rather than the global (`system("make"); Process.last_status.success?`). The same reasoning, for
      # `Regexp.last_match` and `$~`, is {RegexpFolding.fold_last_match}.
      #
      # A bound `$?` is answered as it stands, so the method reads what the global reads in every body the
      # binding rules reach, `Dynamic[top]` in a `define_method` body included. The consult never invents a
      # binding: where `$?` is unbound (rescue clauses, closures, thread roots, joins with a path that ran no
      # subprocess) it declines to the declaration. It also declines an argument-bearing call, whose arity
      # the RBS tier reports.
      #
      # A project that defines `Process.last_status` itself answers `Dynamic[top]`: its method may return
      # anything, and declining would hand the call to the overlay's declaration, which outranks a
      # discovered method. A definition the discovery pass does not record — `def Process.last_status` outside
      # `module Process`, `define_singleton_method`, `alias_method`, a prepended module — keeps the binding's answer.
      module ProcessFolding
        module_function

        # @return the answer, or nil to defer.
        def try_dispatch(context)
          return nil unless SingletonFolding.receiver?(context.receiver, "Process")
          return nil unless context.method_name == :last_status && context.args.empty?

          scope = context.scope
          return nil if scope.nil?
          return Type::Combinator.untyped if project_defines_last_status?(scope)

          scope.global(:$?)
        end

        def project_defines_last_status?(scope)
          return true if scope.discovered_method?("Process", :last_status, :singleton)
          return true if scope.discovered_singleton_def_nodes["Process"]&.key?(:last_status)

          patched = scope.environment&.project_patched_methods
          !patched.nil? && !patched.lookup(class_name: "Process", method_name: :last_status, kind: :singleton).nil?
        end
        private_class_method :project_defines_last_status?
      end
    end
  end
end
