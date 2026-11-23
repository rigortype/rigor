# frozen_string_literal: true

module Rigor
  module Inference
    # Issue #3373 — a module's `def self.included(base)` hook runs when a class includes the module and may define a
    # singleton method on it (`base.define_singleton_method(:x) { … }`), which Ruby calls ahead of an inherited
    # `def self.x`. {.ahead?} is true when a class on the receiver's singleton chain nearer than the `def`'s owner
    # includes a module that writes such a hook, so the call must type `Dynamic` as the `extended` and `inherited`
    # hooks already make it.
    module SingletonIncludedHook
      module_function

      def ahead?(chain, owner, scope)
        resolver = Scope::ResolutionChain.resolver_for(scope, chain.flavor)
        chain.level_classes.each do |klass|
          next if klass.nil?
          return false if klass == owner

          return true if includes_hooked_module?(scope, resolver, klass)
        end
        false
      end

      def includes_hooked_module?(scope, resolver, klass)
        includes = scope.discovery.discovered_includes[klass] || []
        prepends = scope.discovery.discovered_prepends[klass] || []
        includes.uniq.any? do |raw|
          # `prepend M` runs `prepended`, not `included`.
          next false unless includes.count(raw) > prepends.count(raw)

          mixin = resolver.resolve_declared(klass, raw)
          !mixin.nil? && !scope.singleton_def_for(mixin, :included).nil?
        end
      end
    end
  end
end
