# frozen_string_literal: true

require "prism"
require "rigor/plugin"

module Rigor
  module Plugin
    # Example plugin: surfaces deprecation warnings at every
    # call site that matches a user-declared method signature.
    # The smallest worked example of the v0.1.0 plugin authoring
    # surface, and the recommended starting point for "I want to
    # write my own Rigor plugin" — under 80 lines of plugin
    # code, no I/O, no cache, no engine query.
    #
    # The plugin's value is **user-extensibility**: a user
    # extends Rigor's lint surface for their own deprecations
    # by editing `.rigor.yml`, with no plugin-side code. The
    # plugin is the engine; the rules are pure data.
    #
    # ## Configuration
    #
    # Each deprecation entry is a Hash with `method:` (required),
    # plus optional `receiver:`, `replacement:`, and `since:`:
    #
    #     plugins:
    #       - gem: rigor-deprecations
    #         config:
    #           methods:
    #             - method: find_by_sql
    #               receiver: ActiveRecord::Base
    #               replacement: "where(...).to_sql or sanitize_sql"
    #               since: "v6.0"
    #             - method: silence_warnings
    #               replacement: "Warning[:deprecated] = false"
    #               since: "v7.0"
    #
    # `receiver:` matches the literal source text of the call's
    # receiver (`User.find_by_sql(...)` matches `receiver: User`,
    # `ActiveRecord::Base.find_by_sql(...)` matches
    # `receiver: ActiveRecord::Base`). Omitting `receiver:`
    # matches any receiver including no-receiver calls.
    #
    # ## Diagnostic
    #
    # | Event                          | Severity | Rule              |
    # | ---                            | ---      | ---               |
    # | configured deprecation matched | `:warning` | `deprecated-call` |
    class Deprecations < Rigor::Plugin::Base
      manifest(
        id: "deprecations",
        version: "0.1.0",
        description: "Surfaces deprecation warnings for user-declared method signatures.",
        config_schema: {
          "methods" => :array
        }
      )

      Entry = Struct.new(:method_name, :receiver, :replacement, :since, keyword_init: true)

      def init(_services)
        @entries = (config["methods"] || []).map do |row|
          Entry.new(
            method_name: row.fetch("method").to_sym,
            receiver: row["receiver"],
            replacement: row["replacement"],
            since: row["since"]
          )
        end
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        return [] if @entries.empty?

        diagnostics = []
        walk(root) do |node|
          next unless node.is_a?(Prism::CallNode)

          @entries.each do |entry|
            next unless matches?(node, entry)

            diagnostics << build_diagnostic(path, node, entry)
            break # one diagnostic per call site
          end
        end
        diagnostics
      end

      private

      def matches?(call, entry)
        return false unless call.name == entry.method_name
        return true if entry.receiver.nil?

        receiver_source(call.receiver) == entry.receiver
      end

      def receiver_source(node)
        return nil if node.nil?

        node.slice
      end

      def build_diagnostic(path, node, entry)
        suffix = []
        suffix << "since #{entry.since}" if entry.since
        suffix << "use: #{entry.replacement}" if entry.replacement
        tail = suffix.empty? ? "" : " (#{suffix.join("; ")})"
        receiver_label = entry.receiver ? "#{entry.receiver}." : ""
        location = node.location
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: "`#{receiver_label}#{entry.method_name}` is deprecated#{tail}",
          severity: :warning,
          rule: "deprecated-call"
        )
      end

      def walk(node, &block)
        return if node.nil?

        yield node
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end
    end

    Rigor::Plugin.register(Deprecations)
  end
end
