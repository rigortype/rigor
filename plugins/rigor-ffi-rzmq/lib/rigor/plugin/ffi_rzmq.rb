# frozen_string_literal: true

require "rigor/plugin"
require "rigor-ffi"

module Rigor
  module Plugin
    class FFIRZMQ < Base
      manifest(
        id: "ffi-rzmq",
        version: "0.1.0",
        description: "Models ffi-rzmq / LibZMQ wrappers, socket operations, and cross-gem bindings.",
        signature_paths: ["sig"]
      )

      def init(services)
      end

      def prepare(services)
      end

      def diagnostics_for_file(path:, scope:, root:)
        []
      end
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::FFIRZMQ)
