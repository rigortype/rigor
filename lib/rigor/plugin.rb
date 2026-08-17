# frozen_string_literal: true

require_relative "plugin/type_node_resolver"
require_relative "plugin/macro"
require_relative "plugin/manifest"
require_relative "plugin/access_denied_error"
require_relative "plugin/trust_policy"
require_relative "plugin/io_boundary"
require_relative "plugin/fact_store"
require_relative "plugin/services"
require_relative "plugin/base"
require_relative "plugin/node_rule_walk"
require_relative "plugin/registry"
require_relative "plugin/load_error"
require_relative "plugin/box"
require_relative "plugin/isolation"
require_relative "plugin/inflector"
require_relative "plugin/first_party"

module Rigor
  module Plugin
    @registered = {}
    # ADR-88 WD4b — process-global map `gem name (String) => [registered plugin id, ...]`, recorded by the
    # loader the FIRST time a gem's `require` runs its body and registers plugins. A second in-process
    # `Loader.load` of the same bare-string (`id:`-less) entry sees `require` return false (the gem is already
    # loaded, so its `Rigor::Plugin.register` calls do not re-run) and an empty newly-registered delta — the
    # loader recovers the gem's plugin id(s) from this memo instead of failing with "did not register any
    # plugin". Populated by {.record_gem_registration}, read by {.ids_for_gem}. This is what makes a second
    # in-process analysis (the `--verify-incremental` full-run oracle, the incremental session's subset
    # re-analysis, the LSP's re-loads) load the same plugins the first run did.
    @gem_registrations = {}
    @mutex = Mutex.new

    class << self
      def register(plugin_class)
        unless plugin_class.is_a?(Class) && plugin_class < Base
          raise ArgumentError,
                "Rigor::Plugin.register expects a subclass of Rigor::Plugin::Base, got #{plugin_class.inspect}"
        end

        manifest = plugin_class.manifest # rigor:disable undefined-method
        @mutex.synchronize do
          existing = @registered[manifest.id]
          if existing && existing != plugin_class
            raise LoadError.new(
              "plugin id #{manifest.id.inspect} already registered to #{existing}, " \
              "cannot re-register to #{plugin_class}",
              plugin_ref: manifest.id
            )
          end

          @registered[manifest.id] = plugin_class
        end
        plugin_class
      end

      def registered_for(id)
        @mutex.synchronize { @registered[id.to_s] }
      end

      def registered
        @mutex.synchronize { @registered.dup.freeze }
      end

      # ADR-88 WD4b — remember, for a gem loaded for the first time this process, the plugin id(s) its
      # `require` registered. Idempotent (a repeated first-load records the same ids). See {@gem_registrations}.
      def record_gem_registration(gem_name, ids)
        return if gem_name.nil? || ids.nil? || ids.empty?

        @mutex.synchronize { @gem_registrations[gem_name.to_s] = ids.map(&:to_s).freeze }
        nil
      end

      # ADR-88 WD4b — the plugin id(s) `gem_name` registered on its first in-process load, or `[]` when the gem
      # was never loaded this process. The loader consults this when a re-load's `require` no-ops and the
      # newly-registered delta is empty, so a bare-string plugin entry still resolves on the second load.
      def ids_for_gem(gem_name)
        @mutex.synchronize { @gem_registrations[gem_name.to_s] } || []
      end

      def unregister!(id = nil)
        @mutex.synchronize do
          if id.nil?
            @registered.clear
            @gem_registrations.clear
          else
            @registered.delete(id.to_s)
          end
        end
      end
    end
  end
end

require_relative "plugin/loader"
