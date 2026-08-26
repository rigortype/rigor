# frozen_string_literal: true

module Rigor
  module Analysis
    class Diagnostic
      # The default source family. Matches the existing analyzer-internal rule families; serialised as
      # `"builtin"` and is the baseline against which non-default families are recognised.
      DEFAULT_SOURCE_FAMILY = :builtin

      attr_reader :path, :line, :column, :message, :severity, :rule, :source_family,
                  :receiver_type, :method_name, :project_definition_site

      # `rule:` is the stable identifier (a kebab-case string) of the diagnostic's source rule. It is used by
      # the configuration and the in-source `# rigor:disable <rule>` suppression comment system to identify
      # diagnostics by category. Diagnostics not produced by `CheckRules` (parse errors, path errors, internal
      # analyzer errors) may leave `rule` as nil and stay unsuppressible.
      #
      # `source_family:` names the producer of the rule. The default `:builtin` covers analyzer-internal
      # rules; future families like `:rbs_extended`, `:generated`, or `"plugin.<id>"` (per ADR-2 § "Plugin
      # Diagnostic Provenance") let consumers distinguish where a diagnostic originated without committing to
      # the plugin API itself.
      #
      # `receiver_type:` / `method_name:` are optional structured fields populated by the call-related rules
      # (`call.undefined-method`) — the rendered receiver type and the called method name as plain strings.
      # ADR-23 WD3 / slice 4: `rigor triage`'s heuristic recognisers read these directly instead of parsing
      # the diagnostic message, so the catalogue no longer couples to message wording. Both stay nil for
      # rules that have no such pair; a consumer that finds them nil falls back to message parsing.
      #
      # `project_definition_site:` is an optional `"path:line"` string set by `call.undefined-method` when
      # the project itself defines the called method on the receiver class somewhere in the analyzed file set
      # (a reopened core/stdlib/gem class the dispatcher does not apply cross-file — see ADR-17). Its
      # presence is the high-confidence "this is a project monkey-patch, not a bug" signal `rigor triage` keys
      # on to recommend `pre_eval:`. Nil for every other diagnostic.
      def initialize(path:, line:, column:, message:, severity: :error, rule: nil, # rubocop:disable Metrics/ParameterLists
                     source_family: DEFAULT_SOURCE_FAMILY,
                     receiver_type: nil, method_name: nil, project_definition_site: nil)
        raise ArgumentError, "line must be >= 1, got #{line}" if line < 1
        raise ArgumentError, "column must be >= 1, got #{column}" if column < 1

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

      # Builds a Diagnostic positioned at a Prism node. Internalises the load-bearing convention every caller
      # otherwise repeats: the line is the node's 1-based `start_line` and the column is `start_column + 1`
      # (Prism columns are 0-based; Rigor reports 1-based). Pass any node responding to `#location`; all
      # other fields forward to `#initialize` unchanged.
      #
      # `Plugin::Base#diagnostic` wraps this for plugin authors (who must not set `source_family` — the
      # runner stamps it); core rules and other producers call it directly.
      def self.from_node(node, path:, message:, severity: :error, rule: nil, # rubocop:disable Metrics/ParameterLists
                         source_family: DEFAULT_SOURCE_FAMILY,
                         receiver_type: nil, method_name: nil, project_definition_site: nil)
        from_location(
          node.location, path: path, message: message, severity: severity, rule: rule,
                         source_family: source_family, receiver_type: receiver_type,
                         method_name: method_name, project_definition_site: project_definition_site
        )
      end

      # Builds a Diagnostic from an explicit Prism location, applying the same 1-based `line` /
      # `start_column + 1` convention as {.from_node}. Use this when the diagnostic should point at a
      # *sub-location* rather than the whole node — most often a call's `message_loc` (the matcher / method
      # name) instead of the receiver-spanning `node.location`. {.from_node} is sugar for
      # `from_location(node.location, …)`.
      def self.from_location(location, path:, message:, severity: :error, rule: nil, # rubocop:disable Metrics/ParameterLists
                             source_family: DEFAULT_SOURCE_FAMILY,
                             receiver_type: nil, method_name: nil, project_definition_site: nil)
        new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: message, severity: severity, rule: rule, source_family: source_family,
          receiver_type: receiver_type, method_name: method_name,
          project_definition_site: project_definition_site
        )
      end

      # Builds a Diagnostic at a call node's `message_loc` (the method-name / matcher span), falling back to
      # the receiver-spanning `node.location` when no message location is available. Absorbs the
      # `node.message_loc || node.location` idiom the call-related rules otherwise repeat; all other fields
      # forward to {.from_location}.
      def self.from_message_loc(node, **)
        from_location(node.message_loc || node.location, **)
      end

      # Builds a Diagnostic at a definition / assignment node's `name_loc` (the declared name span), falling
      # back to `node.location`. Absorbs the `node.name_loc || node.location` idiom the def / write rules
      # otherwise repeat.
      def self.from_name_loc(node, **)
        from_location(node.name_loc || node.location, **)
      end

      def error?
        severity == :error
      end

      # The fully-qualified rule identifier — `<source_family>.<rule>` when the source is non-default, or
      # just `<rule>` for the `:builtin` family. Returns nil when `rule` itself is nil (e.g. parse errors and
      # internal-analyzer errors).
      def qualified_rule
        return nil if rule.nil?
        return rule if source_family == DEFAULT_SOURCE_FAMILY

        "#{source_family}.#{rule}"
      end

      # `--format json` serialisation. The structured `receiver_type` / `method_name` /
      # `project_definition_site` fields are emitted only when populated, so a consumer (`jq`, `rigor
      # triage`, an AI agent) can group a `rigor check --format json` stream by the called class / method
      # without parsing the human-readable `message` — the message wording is presentation, not contract.
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
        base["receiver_type"] = receiver_type if receiver_type
        base["method_name"] = method_name if method_name
        base["project_definition_site"] = project_definition_site if project_definition_site
        base
      end

      # Text rendering for `rigor check`. The qualified rule identifier (per ADR-2 § "Plugin Diagnostic
      # Provenance" — `call.undefined-method`, `plugin.<id>.<rule>`, `rbs_extended.<rule>`,
      # `generated.<provider>.<rule>`) is appended in brackets.
      #
      # Slice 5 (v0.1.0) introduced the bracket for non-builtin families only, "without changing the layout
      # for built-in rules" — a layout-conservatism call made when provenance was the point, not a judgment
      # that the identifier is noise. The consequence outlived the reason (#431): the exception covers the
      # rules `docs/manual/04-diagnostics.md` tells the reader to suppress with `# rigor:disable <id>` and
      # to key `severity_profile:` on, so the default output was the one place the identifier could not be
      # read. A run could not be grepped for a rule either — the effect-system walkthrough grepped
      # `effect\.` over a whole Redmine run, got nothing, and concluded the feature was broken.
      #
      # The cost is bounded and was measured before the change: on Redmine every diagnostic carries an
      # identifier, only 13 distinct ones appear across the project, and the suffix adds 14 characters to a
      # 165-character median line.
      #
      # `rule` is nil for diagnostics no rule produced — parse errors, path errors, internal analyzer
      # errors — and those stay unsuffixed, because there is nothing to suppress or configure.
      def to_s
        base = "#{path}:#{line}:#{column}: #{severity}: #{message}"
        qualified = qualified_rule
        return base if qualified.nil?

        "#{base} [#{qualified}]"
      end
    end
  end
end
