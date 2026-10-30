# frozen_string_literal: true

module Rigor
  class CLI
    # The version marker every `--format=json` document Rigor defines carries (ADR-126 WD2, ADR-50 WD1).
    #
    # `schema_version` is the first top-level key and counts per document (per `mode` where a flag selects a
    # different document). Adding a key keeps the version; removing or renaming one is a major-only change at
    # v1.0.0. `lens` (`schema`/`revision`), `baseline dump` (`version`) and `check`'s external formats keep
    # their own markers and do not pass through here.
    module JsonDocument
      SCHEMA_VERSION = 1

      # @param payload — the document's top-level object (string or symbol keys).
      # @param mode — names the document when a flag selects among several; nil when the command has one.
      # @return a new Hash whose first key is `schema_version` (then `mode`, when given).
      def self.stamp(payload, mode: nil)
        head = { "schema_version" => SCHEMA_VERSION }
        head["mode"] = mode if mode
        head.merge(payload)
      end

      # The one-line stderr notice for `type-of`, `explain` and `trace`, whose top-level JSON shape changes in
      # the next minor (ADR-126 WD4). stdout stays byte-identical until then. The MCP server appends the same
      # text as its own content block, recognised by {NOTICE_PATTERN}.
      def self.shape_notice(command, replacement)
        "rigor: note — `rigor #{command} --format=json` will print #{replacement} from the next minor " \
          "release (currently a different top-level shape); update JSON consumers now. See ADR-126."
      end

      NOTICE_PATTERN = /^rigor: note — `rigor [a-z-]+ --format=json` will print .*$/

      SHAPE_NOTICES = {
        type_of: shape_notice("type-of", '{ "schema_version": 1, "results": [...] }'),
        trace: shape_notice("trace", '{ "schema_version": 1, "events": [...] }'),
        explain_rules: shape_notice("explain", '{ "schema_version": 1, "rules": [...] }'),
        explain_skip_reasons: shape_notice("explain", '{ "schema_version": 1, "skip_reasons": [...] }')
      }.freeze
    end
  end
end
