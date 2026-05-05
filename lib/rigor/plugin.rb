# frozen_string_literal: true

require_relative "plugin/manifest"
require_relative "plugin/services"
require_relative "plugin/base"
require_relative "plugin/registry"
require_relative "plugin/load_error"

module Rigor
  # Public namespace for the v0.1.0 plugin contract.
  #
  # Rigor plugins are trusted Ruby gems (per ADR-2 § "Plugin Trust
  # and I/O Policy") that subclass {Rigor::Plugin::Base}, declare
  # an identity through {Manifest}, and call {.register} at gem
  # load time so {Rigor::Plugin::Loader} can match the registered
  # class against the project's `.rigor.yml` `plugins:` list.
  #
  # The slice-1 surface is intentionally minimal: registration,
  # discovery, and dependency-injected services. Plugin contribution
  # protocols (dynamic-return facts, type-specifying facts, dynamic
  # reflection) attach in later v0.1.0 slices.
  module Plugin
    @registered = {}
    @mutex = Mutex.new

    class << self
      # Registers a plugin class. Called by the plugin gem at load
      # time — the gem's `lib/rigor-foo.rb` typically ends with
      #
      #   Rigor::Plugin.register(MyFooPlugin)
      #
      # The class' manifest id determines the registration key.
      # Re-registering the same id with the same class is a no-op;
      # registering the same id with a different class raises
      # {LoadError} so two gems cannot silently shadow each other.
      def register(plugin_class)
        unless plugin_class.is_a?(Class) && plugin_class < Base
          raise ArgumentError,
                "Rigor::Plugin.register expects a subclass of Rigor::Plugin::Base, got #{plugin_class.inspect}"
        end

        manifest = plugin_class.manifest
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

      # Returns the plugin class registered under the given id, or
      # `nil` when no class is registered. Used by the loader to
      # resolve `.rigor.yml` plugin entries.
      def registered_for(id)
        @mutex.synchronize { @registered[id.to_s] }
      end

      # Returns a frozen snapshot of the registered { id => class }
      # table. Test helpers and the loader iterate this.
      def registered
        @mutex.synchronize { @registered.dup.freeze }
      end

      # Test helper. Removes one or all registrations. The loader
      # specs use this to reset state between examples.
      def unregister!(id = nil)
        @mutex.synchronize do
          if id.nil?
            @registered.clear
          else
            @registered.delete(id.to_s)
          end
        end
      end
    end
  end
end

require_relative "plugin/loader"
