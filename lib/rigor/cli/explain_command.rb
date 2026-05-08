# frozen_string_literal: true

require "json"
require "optionparser"

require_relative "../analysis/rule_catalog"

module Rigor
  class CLI
    # Executes `rigor explain <rule>`. Prints the catalog entry for
    # one canonical rule id, a legacy alias, or a family wildcard
    # (`call`, `flow`, `assert`, `dump`, `def`).
    #
    # Without arguments lists every rule's id and one-line summary.
    #
    # The command is read-only: no parser, no analyzer, no I/O
    # beyond the rendered catalog. Useful when a user sees a
    # diagnostic in the editor and wants to know what the rule
    # means without leaving the terminal.
    class ExplainCommand
      USAGE = "Usage: rigor explain [options] [<rule>]"

      def initialize(argv:, out:, err:)
        @argv = argv
        @out = out
        @err = err
      end

      # @return [Integer] CLI exit status.
      def run
        options = parse_options

        if @argv.empty?
          render_index(options.fetch(:format))
          return 0
        end

        token = @argv.shift
        entries = Analysis::RuleCatalog.resolve(token)
        if entries.empty?
          @err.puts("Unknown rule: #{token}")
          @err.puts("Run `rigor explain` with no arguments to list every rule.")
          return CLI::EXIT_USAGE
        end

        render_entries(entries, options.fetch(:format))
        0
      end

      private

      def parse_options
        options = { format: "text" }
        OptionParser.new do |opt|
          opt.banner = USAGE
          opt.on("--format=FORMAT", %w[text json], "Output format (text | json). Default: text.") do |fmt|
            options[:format] = fmt
          end
        end.parse!(@argv)
        options
      end

      def render_index(format)
        case format
        when "json" then @out.puts(JSON.pretty_generate(Analysis::RuleCatalog.all.map(&:to_h)))
        else render_index_text
        end
      end

      def render_index_text
        @out.puts("Available rules:")
        @out.puts("")
        Analysis::RuleCatalog.all.each do |entry|
          @out.puts("  #{entry.id.ljust(33)} #{entry.summary}")
        end
        @out.puts("")
        @out.puts("Run `rigor explain <rule>` for the full description.")
        @out.puts("Family wildcards (`call`, `flow`, `assert`, `dump`, `def`) print every rule under that prefix.")
      end

      def render_entries(entries, format)
        case format
        when "json" then @out.puts(JSON.pretty_generate(entries.map(&:to_h)))
        else
          entries.each_with_index do |entry, index|
            @out.puts("") if index.positive?
            render_entry_text(entry)
          end
        end
      end

      def render_entry_text(entry)
        @out.puts(entry.id)
        @out.puts("=" * entry.id.length)
        @out.puts("")
        @out.puts(entry.summary)
        @out.puts("")
        render_aliases(entry)
        render_severity(entry)
        render_section("Fires when:", entry.fires_when)
        render_section("Does not fire when:", entry.does_not_fire_when)
        @out.puts("Suppression: #{entry.suppression}")
        @out.puts("Since: rigor #{entry.since}")
      end

      def render_aliases(entry)
        return if entry.aliases.empty?

        @out.puts("Legacy aliases: #{entry.aliases.join(', ')}")
        @out.puts("")
      end

      def render_severity(entry)
        @out.puts("Authored severity: :#{entry.severity_authored}")
        profile_table = entry.severity_by_profile.map { |profile, sev| "#{profile} → :#{sev}" }.join(", ")
        @out.puts("Severity by profile: #{profile_table}")
        @out.puts("")
      end

      def render_section(heading, items)
        return if items.empty?

        @out.puts(heading)
        items.each { |item| @out.puts("  - #{item}") }
        @out.puts("")
      end
    end
  end
end
