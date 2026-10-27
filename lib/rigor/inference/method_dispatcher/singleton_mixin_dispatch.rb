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

        # True when `class_name`'s instance ancestry carries the stdlib `Singleton` as an `include` written in the
        # class itself or in a project class up its superclass chain (Ruby's `Singleton.included` also installs an
        # `inherited` hook, so `class D < C` answers `instance` with its own instance). Read off
        # `Scope::ResolutionChain` (the `:constants` flavor, so an empty project `module Singleton` is a project
        # entry), where the stdlib module is an external entry. Issue #2438 — what is not the mixin:
        #
        # - `prepend Singleton`, which runs `prepend_features` instead of the `included` hook and so defines no
        #   `instance`; a prepended entry sits ahead of its owner on the chain;
        # - an `include Singleton` in a MODULE the class includes: `Singleton.included` raises `TypeError` for a
        #   module, so that code never runs;
        # - a top-level project `Singleton`, which both `Singleton` and `::Singleton` name.
        #
        # A NESTED project `N::Singleton` the name resolved to is read as the stdlib mixin: the discovery tables
        # drop the leading `::` of a mixin argument, so `include ::Singleton` and `include Singleton` inside
        # `module N` record the same name, and the stdlib reading is the one that types the rooted spelling and
        # never reports a correct call.
        def includes_singleton_mixin?(scope, class_name)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s.delete_prefix("::"), :instance, :constants)
          chain.record(scope)
          classes = chain.level_classes.compact
          chain.entries.each_with_index.any? { |entry, index| singleton_include?(chain, classes, entry, index) }
        end

        def singleton_include?(chain, classes, entry, index)
          if entry.external?
            !entry.superclass_edge && MIXIN_NAMES.include?(entry.raw.to_s) && classes.include?(entry.owner) &&
              index > chain.index_of(entry.owner)
          else
            entry.name.end_with?("::Singleton") && included_by_level_class?(chain, index)
          end
        end

        # The entry sits after its level's class, so it was included into that level rather than prepended.
        def included_by_level_class?(chain, index)
          level = chain.level_starts.rindex { |start| start <= index }
          klass = level && chain.level_classes[level]
          !klass.nil? && index > chain.index_of(klass)
        end
      end
    end
  end
end
