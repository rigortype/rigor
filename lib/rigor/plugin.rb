# frozen_string_literal: true

require_relative "plugin/manifest"
require_relative "plugin/access_denied_error"
require_relative "plugin/trust_policy"
require_relative "plugin/io_boundary"
require_relative "plugin/fact_store"
require_relative "plugin/services"
require_relative "plugin/base"
require_relative "plugin/registry"
require_relative "plugin/load_error"

module Rigor
  module Plugin
    @registered = {}
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
