# frozen_string_literal: true

require "prism"
require "rigor/plugin"

require_relative "web/protocol_checker"

module Rigor
  module Plugin
    # Example plugin: enforces the RigWeb controller protocol.
    #
    # RigWeb (see `demo/lib/rig_web.rb`) is a deliberately tiny routing layer. Its only requirement of a controller is a
    # behavioural one — a controller's action method must take a `Rack::Request` and return a `Rack::Response`. RigWeb
    # never asks a controller to `include` anything; the protocol is a convention, not a declaration.
    #
    # This plugin spotlights the **ADR-28 path-scoped method-protocol contract** extension point — the mechanism that
    # lets a plugin make such a convention statically enforceable WITHOUT the controller class opting in. A contract
    # names:
    #
    # - a path glob (`lib/controller/**/*.rb`) — every class
    #   defined in a matching file is subject to the contract;
    # - a method (`#get`) the class must define;
    # - the parameter type the engine **provides** into that
    #   method's body during inference (`Rack::Request`);
    # - the return type the method's body must **conform to**
    #   (`Rack::Response`).
    #
    # "provide-and-check" is the heart of it. The provide half is engine-side: `Inference::MethodParameterBinder`
    # substitutes `Rack::Request` for the usual `Dynamic[Top]` fallback, so a misuse of the request inside a controller
    # body (`request.no_such_method`) surfaces as an ordinary core diagnostic. The check half is this plugin's
    # `node_rule(Prism::ClassNode)`: for every class the engine-owned walk hands it, it confirms `#get` exists and that
    # its inferred return type conforms to `Rack::Response`. (The check is per class, so it rides the engine's walk
    # rather than shipping a `class_nodes` traversal — contrast the file-level load-error in `rigor-routes`, which
    # genuinely cannot be expressed per node.)
    #
    # ## Configuration
    #
    # The convention path is overridable per project:
    #
    #     plugins:
    #       - gem: rigor-web
    #         config:
    #           controller_path: "app/controllers/**/*.rb"
    #
    # ## Diagnostics
    #
    # | Event                                                  | Severity | Rule                      |
    # | ---                                                    | ---      | ---                       |
    # | a controller class defines no `#get`                   | `:error` | `missing-protocol-method` |
    # | `#get`'s inferred return type is not a `Rack::Response` | `:error` | `protocol-return-mismatch`|
    #
    # A `#get` whose return type the engine cannot pin down (`Dynamic[Top]`) stays silent — the plugin defers to runtime
    # rather than frighten code that may well be correct.
    class Web < Rigor::Plugin::Base
      manifest(
        id: "web",
        version: "0.1.0",
        description: "Enforces the RigWeb controller protocol: #get(Rack::Request) -> Rack::Response.",
        config_schema: {
          # Empty default = "use the manifest's convention path"; a
          # non-empty override retargets every contract's path glob.
          "controller_path" => { kind: :string, default: "" }
        },
        # The plugin ships RBS for Rack::Request / Rack::Response so the analysed project does not need rack installed
        # for the contract's type names to resolve.
        signature_paths: ["sig"],
        protocol_contracts: [
          Rigor::Plugin::ProtocolContract.new(
            path_glob: "lib/controller/**/*.rb",
            method_name: :get,
            param_types: [{ index: 0, type_name: "Rack::Request" }],
            return_type_name: "Rack::Response"
          )
        ]
      )

      def init(_services)
        override = config["controller_path"]
        @protocol_contracts =
          if override.nil? || override.to_s.empty?
            manifest.protocol_contracts
          else
            manifest.protocol_contracts.map { |contract| contract.with_path_glob(override.to_s) }
          end
      end

      # ADR-28 — `Plugin::Base#protocol_contracts` indirection. The manifest declares the default convention path; this
      # override folds in the per-project `controller_path:` config so `.rigor.yml` can retarget the contract (e.g. to
      # Rails' `app/controllers/`). `Plugin::Registry` reads this when it aggregates contracts for the engine's
      # parameter-provision tier; the plugin reads it again here for the check half.
      def protocol_contracts
        @protocol_contracts || manifest.protocol_contracts
      end

      # ADR-37 — per-class-node validation over the engine-owned walk. Each `Prism::ClassNode` is checked against every
      # contract independently of the others, so the plugin no longer ships its own `class_nodes` traversal;
      # `ProtocolChecker#check_class` keeps the per-class contract logic. (Production `rigor-hanami`'s ADR-28 check half
      # still uses `#diagnostics_for_file` + a hand-rolled class walk — an equivalent, older shape; either is
      # contract-valid, but a per-class check is exactly what `node_rule` is for.)
      node_rule Prism::ClassNode do |node, scope, path|
        contracts = protocol_contracts
        next [] if contracts.empty?

        ProtocolChecker.new(contracts: contracts).check_class(node, path: path, scope: scope)
      end
    end

    Rigor::Plugin.register(Web)
  end
end
