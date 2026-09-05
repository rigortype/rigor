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
      # {project_singleton_shadow?}: a project-declared `Singleton` class or module wins and the tier declines,
      # because then the name means something else entirely.
      module SingletonMixinDispatch
        MIXIN_NAMES = Ractor.make_shareable(Set["Singleton", "::Singleton"])
        private_constant :MIXIN_NAMES

        SELECTOR = :instance
        private_constant :SELECTOR

        module_function

        # @return [Rigor::Type, nil] `Nominal[C]` for `C.instance`, or nil to decline.
        def try_dispatch(context)
          return nil unless context.method_name == SELECTOR
          return nil unless context.args.empty?

          receiver = context.receiver
          return nil unless receiver.is_a?(Type::Singleton)

          scope = context.scope
          return nil if scope.nil?
          return nil unless includes_singleton_mixin?(scope, receiver.class_name)
          return nil if project_singleton_shadow?(scope)

          Type::Combinator.nominal_of(receiver.class_name)
        end

        def includes_singleton_mixin?(scope, class_name)
          scope.includes_of(class_name).any? { |name| MIXIN_NAMES.include?(name.to_s) }
        end

        # True when the project declares its OWN `Singleton` class / module, in which case `include Singleton`
        # names that one and the stdlib rule does not apply.
        def project_singleton_shadow?(scope)
          MIXIN_NAMES.any? { |name| scope.discovery.discovered_classes.key?(name.to_s.delete_prefix("::")) }
        end
      end
    end
  end
end
