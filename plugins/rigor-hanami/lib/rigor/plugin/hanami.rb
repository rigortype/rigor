# frozen_string_literal: true

require "prism"
require "rigor/plugin"

require_relative "hanami/action_checker"

module Rigor
  module Plugin
    # rigor-hanami — enforces the Hanami::Action protocol.
    #
    # Hanami 3.x actions inherit from `Hanami::Action` and
    # define a single entry-point:
    #
    #   def handle(request, response)
    #     response.status = 200
    #     response.body = "Hello"
    #   end
    #
    # The method is void — the response is mutated in-place;
    # the return value is discarded by the framework.
    #
    # This plugin uses the **ADR-28 path-scoped
    # method-protocol contract** to:
    #
    # 1. **Provide** `Hanami::Action::Request` and
    #    `Hanami::Action::Response` as the types of the
    #    first and second parameters of every `#handle`
    #    method defined inside `app/actions/**/*.rb`.
    #    The engine substitutes these types for the usual
    #    `Dynamic[Top]` fallback, so misuse of `request` or
    #    `response` inside an action body surfaces as a
    #    core diagnostic.
    #
    # 2. **Check** that every class under `app/actions/`
    #    defines `#handle`. Missing definitions emit
    #    `missing-handle-method`.
    #
    # Return-type conformance is NOT checked — Hanami
    # actions are void by contract, and checking a void
    # return would produce false positives on every `if`
    # branch that doesn't end with an explicit `nil`.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-hanami
    #         config:
    #           action_path: "app/actions/**/*.rb"   # default; optional
    #
    # ## Diagnostics
    #
    # | Event                                    | Severity | Rule                    |
    # | ---                                      | ---      | ---                     |
    # | action class defines no `#handle`        | `:error` | `missing-handle-method` |
    # | `request` / `response` misuse in body    | core engine diagnostic  |
    #
    # A misused `request` or `response` (e.g.
    # `request.no_such_method`) surfaces as a standard
    # engine `call.undefined-method` diagnostic once the
    # plugin provides the parameter types.
    class Hanami < Rigor::Plugin::Base
      manifest(
        id: "hanami",
        version: "0.1.0",
        description: "Enforces the Hanami::Action protocol: #handle(request, response) → void.",
        config_schema: {
          "action_path" => :string
        },
        signature_paths: ["sig"],
        protocol_contracts: [
          Rigor::Plugin::ProtocolContract.new(
            path_glob: "app/actions/**/*.rb",
            method_name: :handle,
            param_types: [
              { index: 0, type_name: "Hanami::Action::Request" },
              { index: 1, type_name: "Hanami::Action::Response" }
            ]
            # return_type_name: nil — void; skip return-type conformance check
          )
        ]
      )

      def init(_services)
        override = config["action_path"]
        @protocol_contracts =
          if override.nil? || override.to_s.empty?
            manifest.protocol_contracts
          else
            manifest.protocol_contracts.map { |c| c.with_path_glob(override.to_s) }
          end
      end

      # ADR-28: override so the per-project `action_path` config
      # reaches both the engine's parameter-provision tier and
      # this plugin's check half.
      def protocol_contracts
        @protocol_contracts || manifest.protocol_contracts
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        contracts = protocol_contracts
        return [] if contracts.empty?

        ActionChecker.new(contracts: contracts).check(path: path, root: root)
      end
    end

    Rigor::Plugin.register(Hanami)
  end
end
