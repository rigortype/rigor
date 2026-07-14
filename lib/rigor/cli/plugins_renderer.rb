# frozen_string_literal: true

require "json"

module Rigor
  class CLI
    # Renderer for `rigor plugins`. Produces a human-readable text table and a JSON representation from the same row
    # shape (the Hash documented on {Rigor::CLI::PluginsCommand#loaded_row}).
    #
    # The two formats carry the same content; JSON is meant for tooling (SKILLs, CI, editor integrations) while text is
    # for interactive inspection. Rows are printed in the order the loader resolved them.
    class PluginsRenderer # rubocop:disable Metrics/ClassLength
      def initialize(rows:, configuration_path:)
        @rows = rows
        @configuration_path = configuration_path
      end

      def text
        lines = []
        lines << header
        lines << ""
        @rows.each_with_index do |row, index|
          lines.concat(row_lines(row))
          lines << "" unless index == @rows.size - 1
        end
        lines << ""
        lines << footer
        lines.join("\n")
      end

      def json
        JSON.pretty_generate(
          {
            "configuration" => @configuration_path,
            "plugins" => @rows.map { |row| row_json(row) },
            "summary" => summary
          }
        )
      end

      # ADR-37 § "Machine-readable capability catalogue" — the focused per-plugin extension-protocol dump. Only loaded
      # plugins appear (a plugin that failed to load contributes no capabilities), and each carries only the gate values
      # an agent enumerates to learn what the plugin does: node-rule node types, dynamic-return receivers,
      # type-specifier methods, and produced / consumed facts.
      def capabilities_json
        JSON.pretty_generate(
          {
            "configuration" => @configuration_path,
            "capabilities" => loaded_rows.map { |row| capabilities_json_for(row) }
          }
        )
      end

      def capabilities_text
        lines = ["Plugin capability catalogue (ADR-37 narrow extension protocols)", ""]
        loaded = loaded_rows
        if loaded.empty?
          lines << "  (no plugins loaded)"
        else
          loaded.each_with_index do |row, index|
            lines.concat(capability_lines(row))
            lines << "" unless index == loaded.size - 1
          end
        end
        lines.join("\n")
      end

      private

      def loaded_rows
        @rows.select { |r| r[:status] == :loaded }
      end

      def capability_lines(row)
        lines = ["  #{row[:id]}  v#{row[:version]}  (#{row[:gem]})"]
        capability_surfaces(row).each { |surface| lines << "        #{surface}" }
        lines << "        (no narrow extension protocols declared)" if lines.size == 1
        lines
      end

      # The non-empty capability surfaces for a plugin, each as a `label: a, b, c` string. Data-driven so the catalogue
      # stays a single source of truth shared between the text and JSON views.
      def capability_surfaces(row)
        [
          ["node_rule", row[:node_rule_types]],
          ["dynamic_return receivers", row[:dynamic_return_receivers]],
          ["narrowing_facts methods", row[:narrowing_facts_methods]],
          ["produces", row[:produces]],
          ["consumes", row[:consumes]]
        ].filter_map { |label, values| "#{label}: #{values.join(', ')}" if values.any? }
      end

      def capabilities_json_for(row)
        {
          "id" => row[:id],
          "gem" => row[:gem],
          "version" => row[:version],
          "node_rule_types" => row[:node_rule_types],
          "dynamic_return_receivers" => row[:dynamic_return_receivers],
          "narrowing_facts_methods" => row[:narrowing_facts_methods],
          "produces" => row[:produces],
          "consumes" => row[:consumes]
        }
      end

      def header
        loaded = @rows.count { |r| r[:status] == :loaded }
        errored = @rows.count { |r| r[:status] == :load_error }
        config = @configuration_path || "(no .rigor.yml found; using defaults)"
        "Plugin activation report\n  " \
          "configuration: #{config}\n  " \
          "loaded: #{loaded}    load-error: #{errored}"
      end

      def footer
        errored = @rows.select { |r| r[:status] == :load_error }
        if errored.empty?
          "All configured plugins loaded successfully."
        else
          "#{errored.size} plugin(s) failed to load — see above. " \
            "Run with --strict to make this a CI gate."
        end
      end

      def row_lines(row)
        marker = row[:status] == :loaded ? "OK " : "ERR"
        head = if row[:status] == :loaded
                 "  [#{marker}] #{row[:id]}  v#{row[:version]}  (#{row[:gem]})"
               else
                 "  [#{marker}] #{row[:gem]}"
               end
        lines = [head]
        lines << "        #{row[:description]}" if row[:description]

        if row[:status] == :load_error
          lines << "        load error: #{row[:load_error]}"
          lines << "        config: #{row[:config].inspect}" if row[:config] && !row[:config].empty?
          return lines
        end

        lines.concat(loaded_detail_lines(row))
        lines
      end

      def loaded_detail_lines(row)
        lines = []
        lines.concat(signature_paths_lines(row[:signature_paths])) if row[:signature_paths].any?
        lines.concat(receiver_and_fact_lines(row))
        lines.concat(macro_substrate_lines(row))
        lines.concat(extra_surface_lines(row))
        lines << "        config: #{row[:config].inspect}" if row[:config] && !row[:config].empty?
        lines
      end

      def receiver_and_fact_lines(row)
        lines = []
        lines << "        open_receivers: #{row[:open_receivers].join(', ')}" if row[:open_receivers].any?
        lines << "        owns_receivers: #{row[:owns_receivers].join(', ')}" if row[:owns_receivers].any?
        lines << "        produces: #{row[:produces].join(', ')}" if row[:produces].any?
        lines << "        consumes: #{row[:consumes].join(', ')}" if row[:consumes].any?
        lines.concat(narrow_protocol_lines(row))
        lines
      end

      # ADR-37 narrow extension protocols (node_rule / dynamic_return / narrowing_facts). Surfaced in the full report
      # alongside the declarative surfaces; `--capabilities` is the focused view.
      def narrow_protocol_lines(row)
        lines = []
        lines << "        node_rule: #{row[:node_rule_types].join(', ')}" if row[:node_rule_types].any?
        if row[:dynamic_return_receivers].any?
          lines << "        dynamic_return receivers: #{row[:dynamic_return_receivers].join(', ')}"
        end
        if row[:narrowing_facts_methods].any?
          lines << "        narrowing_facts methods: #{row[:narrowing_facts_methods].join(', ')}"
        end
        lines
      end

      def extra_surface_lines(row)
        lines = []
        lines << "        protocol_contracts: #{row[:protocol_contracts]}" if row[:protocol_contracts].positive?
        lines << "        source_rbs_synthesizer: yes" if row[:source_rbs_synthesizer]
        lines << "        type_node_resolvers: #{row[:type_node_resolvers]}" if row[:type_node_resolvers].positive?
        if row[:hkt_registrations].positive? || row[:hkt_definitions].positive?
          lines << "        hkt: #{row[:hkt_registrations]} registration(s), #{row[:hkt_definitions]} definition(s)"
        end
        lines
      end

      def signature_paths_lines(paths)
        lines = ["        signature_paths:"]
        paths.each do |entry|
          marker = entry[:exists] ? "" : " (MISSING)"
          lines << "          #{entry[:path]}  (#{entry[:rbs_files]} .rbs file(s))#{marker}"
        end
        lines
      end

      def macro_substrate_lines(row)
        parts = []
        parts << "block_as_methods=#{row[:block_as_methods]}" if row[:block_as_methods].positive?
        parts << "heredoc_templates=#{row[:heredoc_templates]}" if row[:heredoc_templates].positive?
        parts << "trait_registries=#{row[:trait_registries]}" if row[:trait_registries].positive?
        return [] if parts.empty?

        ["        macro substrate: #{parts.join(', ')}"]
      end

      def row_json(row)
        {
          "gem" => row[:gem],
          "status" => row[:status].to_s,
          "id" => row[:id],
          "version" => row[:version],
          "description" => row[:description],
          "config" => row[:config],
          "signature_paths" => row[:signature_paths].map do |sp|
            { "path" => sp[:path], "exists" => sp[:exists], "rbs_files" => sp[:rbs_files] }
          end,
          "open_receivers" => row[:open_receivers],
          "owns_receivers" => row[:owns_receivers],
          "produces" => row[:produces],
          "consumes" => row[:consumes],
          "block_as_methods" => row[:block_as_methods],
          "heredoc_templates" => row[:heredoc_templates],
          "trait_registries" => row[:trait_registries],
          "type_node_resolvers" => row[:type_node_resolvers],
          "hkt_registrations" => row[:hkt_registrations],
          "hkt_definitions" => row[:hkt_definitions],
          "protocol_contracts" => row[:protocol_contracts],
          "source_rbs_synthesizer" => row[:source_rbs_synthesizer],
          "node_rule_types" => row[:node_rule_types],
          "dynamic_return_receivers" => row[:dynamic_return_receivers],
          "narrowing_facts_methods" => row[:narrowing_facts_methods],
          "load_error" => row[:load_error]
        }
      end

      def summary
        {
          "total" => @rows.size,
          "loaded" => @rows.count { |r| r[:status] == :loaded },
          "load_error" => @rows.count { |r| r[:status] == :load_error }
        }
      end
    end
  end
end
