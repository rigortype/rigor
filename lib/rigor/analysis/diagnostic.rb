# frozen_string_literal: true

module Rigor
  module Analysis
    class Diagnostic
      # The default source family. Matches the existing analyzer-
      # internal rule families; serialised as `"builtin"` and is the
      # baseline against which non-default families are recognised.
      DEFAULT_SOURCE_FAMILY = :builtin

      attr_reader :path, :line, :column, :message, :severity, :rule, :source_family,
                  :receiver_type, :method_name, :project_definition_site

      # `rule:` is the stable identifier (a kebab-case string)
      # of the diagnostic's source rule. It is used by the
      # configuration and the in-source `# rigor:disable <rule>`
      # suppression comment system to identify diagnostics by
      # category. Diagnostics not produced by `CheckRules`
      # (parse errors, path errors, internal analyzer errors)
      # may leave `rule` as nil and stay unsuppressible.
      #
      # `source_family:` names the producer of the rule. The default
      # `:builtin` covers analyzer-internal rules; future families
      # like `:rbs_extended`, `:generated`, or `"plugin.<id>"` (per
      # ADR-2 § "Plugin Diagnostic Provenance") let consumers
      # distinguish where a diagnostic originated without committing
      # to the plugin API itself.
      #
      # `receiver_type:` / `method_name:` are optional structured
      # fields populated by the call-related rules (`call.undefined-
      # method`) — the rendered receiver type and the called method
      # name as plain strings. ADR-23 WD3 / slice 4: `rigor triage`'s
      # heuristic recognisers read these directly instead of parsing
      # the diagnostic message, so the catalogue no longer couples to
      # message wording. Both stay nil for rules that have no such
      # pair; a consumer that finds them nil falls back to message
      # parsing.
      #
      # `project_definition_site:` is an optional `"path:line"` string
      # set by `call.undefined-method` when the project itself defines
      # the called method on the receiver class somewhere in the
      # analyzed file set (a reopened core/stdlib/gem class the
      # dispatcher does not apply cross-file — see ADR-17). Its presence
      # is the high-confidence "this is a project monkey-patch, not a
      # bug" signal `rigor triage` keys on to recommend `pre_eval:`.
      # Nil for every other diagnostic.
      def initialize(path:, line:, column:, message:, severity: :error, rule: nil, # rubocop:disable Metrics/ParameterLists
                     source_family: DEFAULT_SOURCE_FAMILY,
                     receiver_type: nil, method_name: nil, project_definition_site: nil)
        @path = path
        @line = line
        @column = column
        @message = message
        @severity = severity
        @rule = rule
        @source_family = source_family
        @receiver_type = receiver_type
        @method_name = method_name
        @project_definition_site = project_definition_site
      end

      def error?
        severity == :error
      end

      # The fully-qualified rule identifier — `<source_family>.<rule>`
      # when the source is non-default, or just `<rule>` for the
      # `:builtin` family. Returns nil when `rule` itself is nil
      # (e.g. parse errors and internal-analyzer errors).
      def qualified_rule
        return nil if rule.nil?
        return rule if source_family == DEFAULT_SOURCE_FAMILY

        "#{source_family}.#{rule}"
      end

      def to_h
        base = {
          "path" => path,
          "line" => line,
          "column" => column,
          "severity" => severity.to_s,
          "rule" => rule,
          "source_family" => source_family.to_s,
          "message" => message
        }
        base["project_definition_site"] = project_definition_site if project_definition_site
        base
      end

      # Text rendering for `rigor check`. The qualified rule
      # identifier (per ADR-2 § "Plugin Diagnostic Provenance" —
      # `plugin.<id>.<rule>`, `rbs_extended.<rule>`,
      # `generated.<provider>.<rule>`) is appended in brackets
      # whenever the diagnostic carries a non-default `source_family`,
      # so plugin / RBS::Extended / generated provenance is visible
      # in the standard text output without changing the layout for
      # built-in rules. Slice 5 (v0.1.0) wires this surface.
      def to_s
        base = "#{path}:#{line}:#{column}: #{severity}: #{message}"
        return base if source_family == DEFAULT_SOURCE_FAMILY

        qualified = qualified_rule
        return base if qualified.nil?

        "#{base} [#{qualified}]"
      end
    end
  end
end
