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
      # The consult reads the binding and never invents one, so it rides every rule that forgets `$?`
      # (rescue clauses, closures, thread roots, joins with a path that ran no subprocess). It declines —
      # deferring to the overlay's `Process::Status?` — when `$?` is unbound or bound to anything but a
      # `Process::Status` (a `define_method` body reads it as `Dynamic[top]`), when the call passes
      # arguments (the RBS tier reports the arity), and when the project defines its own `Process.last_status`.
      module ProcessFolding
        LAST_STATUS = :$?
        private_constant :LAST_STATUS

        module_function

        # @return the bound `$?` type, or nil to defer.
        def try_dispatch(context)
          return nil unless SingletonFolding.receiver?(context.receiver, "Process")
          return nil unless context.method_name == :last_status && context.args.empty?

          scope = context.scope
          return nil if scope.nil? || scope.discovered_method?("Process", :last_status, :singleton)

          status = scope.global(LAST_STATUS)
          status if status.is_a?(Type::Nominal) && status.class_name == "Process::Status"
        end
      end
    end
  end
end
