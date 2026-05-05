# frozen_string_literal: true

require_relative "manifest"

module Rigor
  module Plugin
    # Base class every Rigor plugin subclasses. The plugin gem
    # subclasses {Base}, declares its identity through {.manifest},
    # registers the subclass with {Rigor::Plugin.register}, and
    # overrides {#init} to wire up any state it needs from the
    # injected service container.
    #
    # Slice 1 ships only the registration / loading plumbing. The
    # protocol hooks (dynamic-return contributions, type-specifying
    # contributions, dynamic reflection) land in subsequent v0.1.0
    # slices and arrive as additional methods on this class.
    #
    # Example plugin:
    #
    #   class MyRailsPlugin < Rigor::Plugin::Base
    #     manifest(
    #       id: "rails",
    #       version: "0.1.0",
    #       description: "Rails framework support for Rigor"
    #     )
    #
    #     def init(services)
    #       @reflection = services.reflection
    #       @type = services.type
    #     end
    #   end
    #
    #   Rigor::Plugin.register(MyRailsPlugin)
    class Base
      class << self
        # Declares the plugin's manifest. Called once at class
        # definition time — the resulting {Manifest} is cached on
        # the class so {Rigor::Plugin::Loader} reads it without
        # constructing the plugin.
        def manifest(**fields)
          if fields.empty?
            raise ArgumentError, "plugin #{self} did not declare a manifest" unless defined?(@manifest) && @manifest

            return @manifest
          end

          @manifest = Manifest.new(**fields)
        end
      end

      attr_reader :services, :config

      def initialize(services:, config: {})
        @services = services
        @config = config.freeze
      end

      # Override in subclasses to wire any state the plugin needs
      # from the injected service container. Default is a no-op so
      # plugins that only contribute through later-slice protocol
      # hooks do not have to define an explicit body.
      def init(services) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      # Convenience accessor — `manifest` on the instance returns
      # the class-level manifest declaration.
      def manifest
        self.class.manifest
      end
    end
  end
end
