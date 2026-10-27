# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # `Foo.instance`, where `Foo` includes the stdlib `Singleton` mixin.
      #
      # Ruby grows that class method through a hook — `Singleton.included(klass)` extends the class with
      # `Singleton::SingletonClassMethods` — so nothing static declares it, and the upstream RBS does not close
      # the gap either: `stdlib/singleton/0/singleton.rbs` declares `def self.instance: () -> instance` on the
      # module itself and leaves `module SingletonClassMethods` **empty**. `Singleton.instance` is not a call
      # anyone makes; `Foo.instance` is the entire point of the mixin, and it typed `Dynamic[Top]`.
      #
      # That is expensive out of proportion to its site count, because the value is a whole object: every
      # method called on the returned instance is then dispatched on `Dynamic` too. Mastodon has 365 such
      # calls (`ActivityPub::TagManager.instance`, `FeedManager.instance`, `TagManager.instance`).
      #
      # The rule is exact rather than heuristic — the receiver must be a `Singleton[C]` whose `C` the project
      # pre-pass recorded as including `Singleton` — so a class that does not include the mixin is untouched,
      # and a project that defines its own `Singleton` module is the one case that would misfire. Guarded by
      # {own_singleton_include?}: when the included name resolves to a project-declared class or module (a
      # top-level `Singleton`, or `M::Singleton` inside `module M`), the tier declines, because then the name
      # means something else entirely.
      module SingletonMixinDispatch
        MIXIN_NAMES = Ractor.make_shareable(Set["Singleton", "::Singleton"])
        private_constant :MIXIN_NAMES

        SELECTOR = :instance
        private_constant :SELECTOR

        module_function

        # @return the instance type of `C` for `C.instance`, or nil to decline.
        def try_dispatch(context)
          receiver = context.receiver
          return nil unless answers?(context.scope, receiver, context.method_name, context.args.empty?)

          Type::Combinator.nominal_of(receiver.class_name)
        end

        # Issue #2438 — the one predicate behind {try_dispatch} and `CheckRules#undefined_method_diagnostic`, so the
        # typer and the `call.undefined-method` rule cannot disagree about `C.instance`: a call this tier types is
        # never reported as undefined, whatever a project sidecar of `C` lists.
        def answers?(scope, receiver, method_name, no_arguments)
          return false unless method_name == SELECTOR && no_arguments
          return false unless receiver.is_a?(Type::Singleton)
          return false if scope.nil?

          includes_singleton_mixin?(scope, receiver.class_name)
        end

        # True when `class_name`'s instance ancestry carries the stdlib `Singleton` as an `include` — in the class
        # itself or in a project class up its superclass chain (Ruby's `Singleton.included` also installs an
        # `inherited` hook, so `class D < C` answers `instance` with its own instance). Read off
        # `Scope::ResolutionChain` (the `:constants` flavor, so an empty project `module Singleton` is a project
        # entry), where the stdlib module is an external entry. Issue #2438 — two shapes are not the mixin: a
        # name that resolves to a project constant (a top-level `Singleton`, `M::Singleton` inside `module M`),
        # which is a project entry rather than an external one; and `prepend Singleton`, which runs
        # `prepend_features` instead of the `included` hook and so defines no `instance`. A prepended entry
        # sits ahead of its owner on the chain.
        def includes_singleton_mixin?(scope, class_name)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s.delete_prefix("::"), :instance, :constants)
          chain.record(scope)
          chain.entries.each_with_index.any? do |entry, index|
            entry.external? && !entry.superclass_edge && MIXIN_NAMES.include?(entry.raw.to_s) &&
              included_after_owner?(chain, entry, index)
          end
        end

        def included_after_owner?(chain, entry, index)
          owner = entry.owner && chain.index_of(entry.owner)
          !owner.nil? && index > owner
        end
      end
    end
  end
end
