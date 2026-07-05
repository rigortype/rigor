# frozen_string_literal: true

require "json"
require "digest"
require_relative "../version"

module Rigor
  class CLI
    # CI-native diagnostic output formats (ADR-51). Each renders an `Analysis::Result` to a string a CI platform
    # consumes to surface diagnostics inline in a pull / merge request, rather than only in the job log. They read the
    # same `Diagnostic` fields as `--format json` (path / line / column / severity / qualified rule / message) and add
    # no new information — only a platform-native rendering of it.
    #
    #   sarif      — SARIF 2.1.0 (cross-platform; GitHub code-scanning, any
    #                other SARIF tool, and reviewdog `-f=sarif`)
    #   github     — GitHub Actions workflow commands (`::error file=…,line=…::`)
    #                that the runner turns into inline PR annotations
    #   gitlab     — GitLab Code Quality report JSON (the CodeClimate subset)
    #                that drives the merge-request Code Quality widget
    #   checkstyle — Checkstyle XML, the broad lint-interchange format that
    #                reviewdog (`-f=checkstyle`) and Jenkins/etc. consume
    #   junit      — JUnit XML, the test-report format many CI systems render
    #
    # Severity maps once per format from Rigor's `:error` / `:warning` / `:info`; the qualified rule
    # (`<source_family>.<rule>` or the bare rule for the builtin family) is the stable identifier, nil only for the
    # ruleless producers (parse / internal errors), which each format degrades gracefully.
    module DiagnosticFormats
      FORMATS = %w[sarif github gitlab checkstyle junit teamcity].freeze

      module_function

      def supports?(format)
        FORMATS.include?(format)
      end

      # Renders `result` in the named CI format. Callers gate on {.supports?} first; an unrecognised format returns nil.
      def render(result, format)
        case format
        when "sarif" then Sarif.new(result).render
        when "github" then GithubActions.new(result).render
        when "gitlab" then GitlabCodeQuality.new(result).render
        when "checkstyle" then Checkstyle.new(result).render
        when "junit" then Junit.new(result).render
        when "teamcity" then Teamcity.new(result).render
        end
      end

      # XML attribute / text escaping shared by the Checkstyle and JUnit formatters. Covers the five predefined XML
      # entities so a diagnostic message carrying `<`, `&`, or a quote can't break the document.
      module XmlEscaping
        ENTITIES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;",
                     '"' => "&quot;", "'" => "&apos;" }.freeze

        def xml_escape(value)
          value.to_s.gsub(/[&<>"']/, ENTITIES)
        end
      end

      # SARIF 2.1.0 — the OASIS static-analysis interchange format. GitHub's `codeql-action/upload-sarif` ingests it to
      # render findings on the PR diff and in the Security tab; it is the cross-platform anchor format.
      class Sarif
        SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"
        INFORMATION_URI = "https://github.com/rigortype/rigor"

        # SARIF defines exactly three result levels; Rigor's `:info` is a `note` (the SARIF spelling for advisory
        # findings).
        LEVELS = { error: "error", warning: "warning", info: "note" }.freeze

        def initialize(result)
          @result = result
        end

        def render
          JSON.pretty_generate(document)
        end

        private

        def document
          { "version" => "2.1.0", "$schema" => SCHEMA, "runs" => [run] }
        end

        def run
          {
            "tool" => { "driver" => driver },
            "results" => @result.diagnostics.map { |diagnostic| result_for(diagnostic) }
          }
        end

        def driver
          {
            "name" => "Rigor",
            "informationUri" => INFORMATION_URI,
            "version" => Rigor::VERSION,
            "rules" => rules
          }
        end

        # The distinct rule ids seen in this run, declared so consumers can cross-reference each result's `ruleId`.
        # Id-only is a valid minimal SARIF rule object; richer per-rule metadata is a later enrichment.
        def rules
          @result.diagnostics.filter_map(&:qualified_rule).uniq.map { |id| { "id" => id } }
        end

        def result_for(diagnostic)
          entry = {
            "level" => LEVELS.fetch(diagnostic.severity, "warning"),
            "message" => { "text" => diagnostic.message },
            "locations" => [location_for(diagnostic)]
          }
          rule_id = diagnostic.qualified_rule
          entry["ruleId"] = rule_id if rule_id
          entry
        end

        # Rigor lines / columns are already 1-based, matching SARIF's 1-based `startLine` / `startColumn`. Paths are
        # project-relative; SARIF URIs use forward slashes on every platform.
        def location_for(diagnostic)
          {
            "physicalLocation" => {
              "artifactLocation" => { "uri" => diagnostic.path.to_s.tr("\\", "/") },
              "region" => { "startLine" => diagnostic.line, "startColumn" => diagnostic.column }
            }
          }
        end
      end

      # GitHub Actions workflow commands — `::<level> file=…,line=…,col=…, title=…::<message>` lines the runner parses
      # out of stdout and turns into inline PR annotations, with no separate upload step.
      class GithubActions
        # GitHub's annotation levels; Rigor's `:info` is a `notice`.
        LEVELS = { error: "error", warning: "warning", info: "notice" }.freeze

        def initialize(result)
          @result = result
        end

        def render
          @result.diagnostics.map { |diagnostic| line_for(diagnostic) }.join("\n")
        end

        private

        def line_for(diagnostic)
          level = LEVELS.fetch(diagnostic.severity, "warning")
          props = ["file=#{escape_property(diagnostic.path)}",
                   "line=#{diagnostic.line}", "col=#{diagnostic.column}"]
          rule_id = diagnostic.qualified_rule
          props << "title=#{escape_property(rule_id)}" if rule_id
          "::#{level} #{props.join(',')}::#{escape_data(diagnostic.message)}"
        end

        # GitHub's documented workflow-command escaping: `%` and the CR / LF that would otherwise terminate the command
        # line, for message data.
        def escape_data(value)
          value.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
        end

        # Property values additionally escape the `,` (property separator) and `:` (command terminator) so a path or
        # rule id can carry them.
        def escape_property(value)
          escape_data(value).gsub(",", "%2C").gsub(":", "%3A")
        end
      end

      # GitLab Code Quality report — the CodeClimate-subset JSON array GitLab reads from a `codequality` CI artifact to
      # populate the merge-request Code Quality widget.
      class GitlabCodeQuality
        # GitLab's severity vocabulary (a CodeClimate subset). Rigor maps error → major, warning → minor, info → info;
        # `critical` / `blocker` are left for a louder future tier.
        SEVERITIES = { error: "major", warning: "minor", info: "info" }.freeze

        def initialize(result)
          @result = result
        end

        def render
          JSON.pretty_generate(@result.diagnostics.map { |diagnostic| entry_for(diagnostic) })
        end

        private

        def entry_for(diagnostic)
          {
            "description" => description(diagnostic),
            "check_name" => diagnostic.qualified_rule || "rigor",
            "fingerprint" => fingerprint(diagnostic),
            "severity" => SEVERITIES.fetch(diagnostic.severity, "minor"),
            "location" => {
              "path" => diagnostic.path.to_s,
              "lines" => { "begin" => diagnostic.line }
            }
          }
        end

        # The rule id is folded into the description (the widget shows it) because Code Quality has no dedicated rule
        # field.
        def description(diagnostic)
          rule_id = diagnostic.qualified_rule
          rule_id ? "#{diagnostic.message} [#{rule_id}]" : diagnostic.message
        end

        # GitLab dedups findings by fingerprint and tracks them across runs by it, so it must be stable for an unchanged
        # finding and unique per finding. Hashing the locating tuple (path, rule, line, column, message) satisfies both
        # — order-independent, no run-volatile input.
        def fingerprint(diagnostic)
          payload = [diagnostic.path, diagnostic.qualified_rule, diagnostic.line,
                     diagnostic.column, diagnostic.message].join(" ")
          Digest::SHA256.hexdigest(payload)
        end
      end

      # Checkstyle XML — the lint-interchange format a wide range of tools read, most usefully reviewdog
      # (`-f=checkstyle`), which then posts to any of its reporters (GitHub PR review, GitLab MR, Gerrit, …). Errors are
      # grouped by file; the qualified rule rides in `source` (the rule code reviewdog surfaces). Checkstyle's native
      # severities are `error` / `warning` / `info`, so Rigor's map through unchanged.
      class Checkstyle
        include XmlEscaping

        def initialize(result)
          @result = result
        end

        def render
          lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<checkstyle>"]
          @result.diagnostics.group_by(&:path).each do |path, diagnostics|
            lines << %(  <file name="#{xml_escape(path)}">)
            diagnostics.each { |diagnostic| lines << error_element(diagnostic) }
            lines << "  </file>"
          end
          lines << "</checkstyle>"
          lines.join("\n")
        end

        private

        def error_element(diagnostic)
          attrs = %(line="#{diagnostic.line}" column="#{diagnostic.column}" ) +
                  %(severity="#{diagnostic.severity}" message="#{xml_escape(diagnostic.message)}")
          rule_id = diagnostic.qualified_rule
          attrs += %( source="#{xml_escape(rule_id)}") if rule_id
          "    <error #{attrs} />"
        end
      end

      # JUnit XML — the test-report format GitHub's test reporting, GitLab, Jenkins, and CircleCI render. Following the
      # established linter convention (rubocop / eslint / PHPStan): every diagnostic is a `testcase` carrying a
      # `failure` typed by its severity, so all of them are visible in the report. The exit code (errors only) remains
      # the gate; this view is for surfacing, not gating.
      class Junit
        include XmlEscaping

        def initialize(result)
          @result = result
        end

        def render
          diagnostics = @result.diagnostics
          # JUnit wants at least one test; a clean run reports one passing case.
          tests = diagnostics.empty? ? 1 : diagnostics.size
          lines = ['<?xml version="1.0" encoding="UTF-8"?>',
                   %(<testsuite name="rigor" tests="#{tests}" failures="#{diagnostics.size}">)]
          if diagnostics.empty?
            lines << '  <testcase name="rigor" />'
          else
            diagnostics.each { |diagnostic| lines.concat(testcase(diagnostic)) }
          end
          lines << "</testsuite>"
          lines.join("\n")
        end

        private

        def testcase(diagnostic)
          name = "#{diagnostic.path}:#{diagnostic.line}:#{diagnostic.column}"
          classname = diagnostic.qualified_rule || "rigor"
          [
            %(  <testcase name="#{xml_escape(name)}" classname="#{xml_escape(classname)}">),
            %(    <failure type="#{diagnostic.severity}" message="#{xml_escape(diagnostic.message)}" />),
            "  </testcase>"
          ]
        end
      end

      # TeamCity inspection service messages — the `##teamcity[…]` lines a TeamCity build agent parses out of the build
      # log into its Inspections view. The one stdout-native format (besides `github`) that CI-detection auto-emits. One
      # `inspectionType` declares the category; each diagnostic is an `inspection` typed by severity.
      class Teamcity
        SEVERITIES = { error: "ERROR", warning: "WARNING", info: "INFO" }.freeze

        def initialize(result)
          @result = result
        end

        def render
          return "" if @result.diagnostics.empty?

          lines = [message("inspectionType", id: "rigor", name: "rigor",
                                             category: "rigor", description: "Rigor inspection")]
          @result.diagnostics.each { |diagnostic| lines << inspection(diagnostic) }
          lines.join("\n")
        end

        private

        def inspection(diagnostic)
          rule_id = diagnostic.qualified_rule
          text = rule_id ? "#{diagnostic.message} [#{rule_id}]" : diagnostic.message
          message("inspection", typeId: "rigor", message: text, file: diagnostic.path,
                                line: diagnostic.line, SEVERITY: SEVERITIES.fetch(diagnostic.severity, "WARNING"))
        end

        def message(name, attrs)
          pairs = attrs.map { |key, value| "#{key}='#{escape(value)}'" }.join(" ")
          "##teamcity[#{name} #{pairs}]"
        end

        # TeamCity's documented service-message escaping.
        def escape(value)
          value.to_s.gsub("|", "||").gsub("'", "|'").gsub("\n", "|n")
               .gsub("\r", "|r").gsub("[", "|[").gsub("]", "|]")
        end
      end
    end
  end
end
