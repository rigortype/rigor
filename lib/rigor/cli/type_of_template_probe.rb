# frozen_string_literal: true

require "prism"

require_relative "../analysis/template_unit_paths"
require_relative "../analysis/template_unit_positions"
require_relative "../analysis/template_units"
require_relative "../inference/precision_scanner"
require_relative "../inference/scope_indexer"
require_relative "../source/node_locator"

module Rigor
  class CLI
    # #1040 — `rigor type-of` against a **template unit**: a file a loaded plugin compiles into Ruby.
    #
    # Before this the command read the template from disk and parsed its bytes as Ruby, so an ERB view
    # exited 1 on a parse error and an identity-transformed one answered about the wrong node under an
    # unseeded scope. A template path now takes the path `rigor check` takes: the run's
    # {Analysis::TemplateUnits} index is built, the COMPILED source is parsed with the unit's `scopes:`, the
    # file scope is seeded with the unit's `self`, locals and ivars, and the requested template position is
    # resolved through {Analysis::TemplateUnitPositions} — which declines, with a message, whenever the
    # position does not denote exactly one compiled node.
    #
    # Mixed into {TypeOfCommand}; a path no loaded plugin claims never reaches anything here, so a `.rb`
    # probe does not build the index or change a byte of its output.
    module TypeOfTemplateProbe
      # Why a template position has no answer, keyed by {Analysis::TemplateUnitPositions#node_at}'s reasons.
      DECLINE_MESSAGES = {
        no_compiled_line: "the template compiler emitted no Ruby for this line",
        not_verbatim: "the position is in template markup, or in code the template compiler rewrote " \
                      "rather than copied, so no compiled expression is made of the bytes there",
        ambiguous: "the bytes there were copied to more than one place in the compiled Ruby, " \
                   "so the position does not name a single expression"
      }.freeze
      private_constant :DECLINE_MESSAGES

      private

      # The unit `file` compiles to, `nil` for a path that is not a template unit (the caller probes it as
      # Ruby), or an exit status after reporting a template the claiming plugin could not compile.
      def template_unit_probe(file, environment, buffer)
        registry = environment.plugin_registry
        return nil unless template_claimed?(registry, file)

        units = (@template_units ||= Analysis::TemplateUnits.collect(registry: registry, buffer: buffer))
        entry = units[file]
        return [units, entry] if entry

        # A template the plugin DECLINED is not a unit, and is probed as the command always probed it.
        failures = template_failures(units, file)
        return nil if failures.empty?

        failures.each do |failure|
          @err.puts("type-of: #{file}: plugin #{failure.plugin_id} could not compile the template: " \
                    "#{failure.message}")
        end
        1
      end

      # Only a claimed path builds the index — a `.rb` probe pays no glob expansion and no transform.
      def template_claimed?(registry, file)
        return false if registry.nil? || registry.empty?

        relative = Analysis::TemplateUnitPaths.relative(file, Dir.pwd)
        registry.plugins.any? do |plugin|
          globs = begin
            plugin.manifest.template_globs
          rescue StandardError
            []
          end
          !globs.empty? && Analysis::TemplateUnitPaths.claims?(globs, relative)
        end
      end

      def template_failures(units, file)
        relative = Analysis::TemplateUnitPaths.relative(file, Dir.pwd)
        units.failures.select { |failure| failure.path == relative }
      end

      # Every result for one template: the compiled source parsed and indexed once under the unit's seeded
      # scope, then each requested template position resolved through the inverse map.
      def resolve_template(file, physical, unit_probe, indexed_targets, context)
        units, entry = unit_probe
        parse_result = Prism.parse(entry.source, filepath: file, version: context[:configuration].target_ruby,
                                                 scopes: units.parse_scopes(file))
        return 1 if compiled_parse_errors?(parse_result, file, entry)

        scope = units.seed(context[:base_scope].with_source_path(file), file)
        scope_index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        positions = Analysis::TemplateUnitPositions.new(
          entry: entry, template: File.binread(physical), root: parse_result.value,
          skip_node_types: Inference::PrecisionScanner::NON_EXPRESSION_NODE_TYPES
        )
        probe = { file: file, entry: entry, positions: positions, scope_index: scope_index,
                  options: context[:options] }
        indexed_targets.map do |target, index|
          resolved = resolve_template_target(probe, target)
          return resolved if resolved.is_a?(Integer)

          [index, resolved]
        end
      end

      def resolve_template_target(probe, target)
        file = probe[:file]
        positions = probe[:positions]
        return CLI::EXIT_USAGE unless template_position_in_range?(positions, target)
        return enumerate_template_line(probe, target.line) if target.column.nil?

        node = positions.node_at(line: target.line, column: target.column)
        if node.is_a?(Symbol)
          @err.puts("type-of: no expression found at #{file}:#{target.line}:#{target.column}: " \
                    "#{DECLINE_MESSAGES.fetch(node)}")
          return []
        end

        [type_result(file, target.line, target.column, node, probe[:scope_index], probe[:options],
                     location_mapper: template_location_mapper(probe))]
      end

      def enumerate_template_line(probe, line)
        unless line.between?(1, probe[:positions].template_line_count)
          @err.puts("type-of: no expression found on #{probe[:file]}:#{line}")
          return []
        end

        rows, total = probe[:positions].line_nodes(line)
        if rows.empty?
          @err.puts("type-of: no expression found on #{probe[:file]}:#{line}: no compiled expression maps to " \
                    "a single column of this line (markup, code the template compiler rewrote, or code " \
                    "copied to more than one place)")
          return []
        end

        enumeration = TypeOfCommand::LineEnumeration.new(total: total, shown: rows.length)
        mapper = template_location_mapper(probe)
        rows.map do |column, node|
          type_result(probe[:file], line, column, node, probe[:scope_index], probe[:options],
                      enumeration: enumeration, location_mapper: mapper)
        end
      end

      # The same range errors, and the same exit status, a `.rb` probe gives — measured against the
      # TEMPLATE's lines, which are the ones the user named. A bare `FILE:LINE` past the end is "no
      # expression found", exactly as it is for Ruby.
      def template_position_in_range?(positions, target)
        return true if target.column.nil?

        message = if target.line < 1 then "line must be >= 1, got #{target.line}"
                  elsif target.column < 1 then "column must be >= 1, got #{target.column}"
                  elsif target.line > positions.template_line_count
                    "line #{target.line} is past the end of the source buffer"
                  end
        return true if message.nil?

        @err.puts("type-of: #{message}")
        false
      end

      # A `--trace` fallback carries a COMPILED location; it is reported at the template line, and at a
      # template column only when the location lies in a verbatim run.
      def template_location_mapper(probe)
        entry = probe[:entry]
        positions = probe[:positions]
        lambda do |location|
          [entry.template_line(location.start_line), positions.template_column_for(location)]
        end
      end

      # A compiled source that does not parse is the plugin's output, not the user's text; its errors are
      # reported at the template lines they map to, as `rigor check` reports every other finding in a unit.
      def compiled_parse_errors?(result, file, entry)
        return false if result.errors.empty?

        result.errors.each do |error|
          @err.puts("#{file}:#{entry.template_line(error.location.start_line)}: " \
                    "compiled template does not parse: #{error.message}")
        end
        true
      end
    end
  end
end
