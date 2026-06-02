# frozen_string_literal: true

# Fixture: a third-party-style Rigor plugin that lives OUTSIDE the
# monorepo's `plugins/` and `examples/` trees. It depends only on the
# PUBLIC plugin contract (ADR-2) — the same surface an external author
# writing a `rigor-foo` gem in their own repo (ADR-31 WD4) has:
#
#   - `require "rigor/plugin"` + `Rigor::Plugin::Base`
#   - `node_rule` (ADR-37, the engine owns the walk)
#   - `#diagnostic` (the author-helper that internalises the
#     1-based line / `start_column + 1` convention)
#   - `config_schema` `{kind:, default:}` declared defaults (ADR-40)
#   - `Rigor::Source::Literals` (the pinned literal-extraction helpers)
#
# The integration spec (`spec/integration/external_plugin_spec.rb`)
# loads this via the REAL `require` path and runs it end-to-end through
# `Analysis::Runner`, so any drift in those public surfaces breaks the
# test — it is the executable evidence for v0.2.0 gate 1 (the plugin
# contract is stable enough for out-of-tree gems).
require "prism"
require "rigor/plugin"
require "rigor/source/literals"

module Rigor
  module Plugin
    class ExternalDemo < Rigor::Plugin::Base
      manifest(
        id: "external-demo",
        version: "0.1.0",
        description: "Fixture third-party plugin exercising the public plugin contract.",
        config_schema: {
          "flagged_method" => { kind: :string, default: "legacy_call" }
        }
      )

      # The engine hands every CallNode to this rule; we flag the
      # configured method name (defaulting via the ADR-40 schema default,
      # read with no `DEFAULT_*` constant) and, when the first argument
      # is a literal symbol, name it via the shared `Source::Literals`
      # helper.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless node.name.to_s == config.fetch("flagged_method")

        first_symbol = Rigor::Source::Literals.symbol(node.arguments&.arguments&.first)
        detail = first_symbol ? " (:#{first_symbol})" : ""
        [diagnostic(
          node, path: path,
                message: "`#{node.name}` is flagged by rigor-external-demo#{detail}",
                severity: :warning,
                rule: "flagged-call"
        )]
      end
    end

    Rigor::Plugin.register(ExternalDemo)
  end
end
