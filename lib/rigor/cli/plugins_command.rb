# frozen_string_literal: true

require "optparse"

require_relative "../configuration"
require_relative "../plugin"
require_relative "../plugin/loader"
require_relative "../plugin/services"
require_relative "../reflection"
require_relative "../type/combinator"
require_relative "plugins_renderer"
require_relative "command"

module Rigor
  class CLI
    # `rigor plugins` — reports the activation status of every
    # plugin entry in `.rigor.yml` so users (and the
    # `rigor-project-init` SKILL, CI gates, `rigor init`) can
    # verify their plugin configuration is actually doing what
    # they think.
    #
    # The command is read-only and idempotent: it loads the
    # project's `.rigor.yml` (same discovery as `rigor check`),
    # runs `Plugin::Loader.load` to attempt instantiation, then
    # prints a table of:
    #
    # - load status (`loaded` / `load-error` with reason);
    # - resolved manifest id, version, description;
    # - `signature_paths:` (absolute paths + per-dir `.rbs` count);
    # - every manifest-declared extension surface
    #   (`open_receivers:` / `owns_receivers:` / `produces:` /
    #   `consumes:` / `block_as_methods:` / `heredoc_templates:` /
    #   `trait_registries:` /
    #   `type_node_resolvers:` / `hkt_registrations:` /
    #   `hkt_definitions:` / `protocol_contracts:` /
    #   `source_rbs_synthesizer:`);
    # - the ADR-37 narrow extension protocols read off the plugin
    #   class — `node_rule` node types, `dynamic_return` receivers,
    #   `type_specifier` methods.
    #
    # `--capabilities` switches to a focused catalogue of just the
    # narrow-protocol gate values + produced/consumed facts (ADR-37
    # § "Machine-readable capability catalogue") — the AI-legibility
    # surface that lets an agent enumerate what every plugin does.
    #
    # Output formats: `text` (default, human-readable table) and
    # `json` (for tooling — SKILLs, CI gates, editor integrations).
    #
    # Exit codes:
    # - `0` — every configured plugin loaded.
    # - `1` — at least one plugin failed to load AND `--strict`
    #   was passed. Without `--strict` the command always exits 0;
    #   load errors are reported but not treated as a gate failure
    #   (matching `rigor triage`'s advisory shape).
    #
    # Future expansion (not in this slice):
    # - Per-plugin diagnostic counts (would require running the
    #   full analysis pipeline; out of scope for an inspection
    #   command).
    # - Verification that `signature_paths` actually merged into
    #   the RBS environment without conflict (requires constructing
    #   the Environment, which is heavier than the loader-only
    #   pass this slice does).
    class PluginsCommand < Command # rubocop:disable Metrics/ClassLength
      USAGE = "Usage: rigor plugins [options]"

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        config_path = options.fetch(:config) || Configuration.discover
        configuration = Configuration.load(options.fetch(:config))
        rows = build_rows(configuration)

        renderer = PluginsRenderer.new(rows: rows, configuration_path: config_path)
        @out.puts(render(renderer, options))

        any_load_errors = rows.any? { |row| row.fetch(:status) == :load_error }
        return 1 if any_load_errors && options.fetch(:strict)

        0
      end

      private

      # Picks the renderer view. `--capabilities` switches to the
      # focused extension-protocol catalogue (ADR-37 § "Machine-readable
      # capability catalogue") — per plugin, only the gate values that
      # tell a reader (or an AI agent) exactly what the plugin
      # contributes: the node-rule node types, the dynamic-return
      # receivers, the type-specifier methods, and the produced /
      # consumed facts. The default view stays the full activation report.
      def render(renderer, options)
        json = options.fetch(:format) == "json"
        if options.fetch(:capabilities)
          json ? renderer.capabilities_json : renderer.capabilities_text
        else
          json ? renderer.json : renderer.text
        end
      end

      def parse_options
        options = { config: nil, format: "text", strict: false, capabilities: false }
        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |v| options[:format] = v }
          opts.on("--strict", "Exit 1 if any plugin failed to load (CI gate)") { options[:strict] = true }
          opts.on("--capabilities", "Emit the per-plugin extension-protocol catalogue (ADR-37)") do
            options[:capabilities] = true
          end
        end.parse!(@argv)
        validate!(options)
        options
      end

      def validate!(options)
        return if %w[text json].include?(options.fetch(:format))

        raise OptionParser::InvalidArgument, "unsupported format: #{options.fetch(:format)}"
      end

      # Runs the plugin loader against the project configuration
      # and returns a row per declared plugin entry. Each row is
      # a plain Hash with the fields enumerated in the class
      # docstring so the renderer (text + JSON) reads from a
      # single shape.
      #
      # The loader catches require / init failures and surfaces
      # them through `registry.load_errors`; we merge those back
      # into the per-entry rows by matching on `plugin_ref`.
      def build_rows(configuration)
        services = build_services(configuration)
        registry = Plugin::Loader.load(configuration: configuration, services: services)

        rows = configuration.plugins.map { |entry| row_for_entry(entry, registry) }
        # Surface registry-level errors that did not bind to an
        # entry (e.g. dependency-cycle errors that name multiple
        # plugins). The renderer treats these as "orphan" errors.
        orphan_errors = orphan_load_errors(registry, rows)
        rows + orphan_errors
      end

      def build_services(configuration)
        Plugin::Services.new(
          reflection: Reflection,
          type: Type::Combinator,
          configuration: configuration,
          cache_store: nil
        )
      end

      def row_for_entry(entry, registry)
        gem_name = entry_gem_name(entry)
        config = entry_config(entry)
        plugin = registry.plugins.find do |p|
          # The loader has already matched the entry to a plugin
          # class; we can identify it by either the gem name (when
          # the entry was a String) or the explicit id (when the
          # entry was a Hash with `id:`).
          plugin_matches_entry?(p, gem_name, entry_id(entry))
        end

        if plugin
          loaded_row(plugin, gem_name, config)
        else
          # Find the load error whose plugin_ref names this entry
          # (the ref is set by Loader to the gem name on require
          # failures and to the manifest id on later failures).
          error = registry.load_errors.find do |e|
            ref = e.plugin_ref.to_s
            ref == gem_name || ref == entry_id(entry).to_s
          end
          load_error_row(gem_name, entry_id(entry), config, error)
        end
      end

      def plugin_matches_entry?(plugin, gem_name, entry_id)
        return true if entry_id && plugin.manifest.id == entry_id

        # A bare gem entry conventionally has manifest.id equal to
        # the gem name with the `rigor-` prefix stripped.
        derived_id = gem_name.delete_prefix("rigor-")
        [derived_id, gem_name].include?(plugin.manifest.id)
      end

      def loaded_row(plugin, gem_name, config)
        manifest = plugin.manifest
        identity_fields(gem_name, manifest, config)
          .merge(extension_fields(plugin, manifest))
          .merge(narrow_protocol_fields(plugin))
          .merge(load_error: nil)
      end

      # ADR-37 narrow extension protocols. Unlike the 10 declarative
      # manifest fields, these are class-level DSLs (`node_rule` /
      # `dynamic_return` / `type_specifier`), so they are read off the
      # plugin class rather than the manifest. The gate values — node
      # types, receiver class names, specified method names — are the
      # greppable, enumerable surface the capability catalogue exposes.
      def narrow_protocol_fields(plugin)
        klass = plugin.class
        {
          node_rule_types: klass.node_rules.map { |r| r[:node_type].name }.uniq,
          dynamic_return_receivers: klass.dynamic_returns.flat_map { |r| r[:receivers] }.uniq,
          type_specifier_methods: klass.type_specifiers.flat_map { |r| r[:methods] }.map(&:to_s).uniq
        }
      end

      def identity_fields(gem_name, manifest, config)
        {
          gem: gem_name,
          status: :loaded,
          id: manifest.id,
          version: manifest.version,
          description: manifest.description,
          config: config
        }
      end

      def extension_fields(plugin, manifest)
        {
          signature_paths: signature_path_rows(plugin),
          open_receivers: manifest.open_receivers.dup,
          owns_receivers: manifest.owns_receivers.dup,
          produces: manifest.produces.map(&:to_s),
          consumes: manifest.consumes.map { |c| "#{c.plugin_id}/#{c.name}#{'?' if c.optional}" },
          source_rbs_synthesizer: !manifest.source_rbs_synthesizer.nil?
        }.merge(extension_count_fields(manifest))
      end

      def extension_count_fields(manifest)
        {
          block_as_methods: manifest.block_as_methods.size,
          heredoc_templates: manifest.heredoc_templates.size,
          trait_registries: manifest.trait_registries.size,
          type_node_resolvers: manifest.type_node_resolvers.size,
          hkt_registrations: manifest.hkt_registrations.size,
          hkt_definitions: manifest.hkt_definitions.size,
          protocol_contracts: manifest.protocol_contracts.size
        }
      end

      def load_error_row(gem_name, entry_id, config, error)
        {
          gem: gem_name,
          status: :load_error,
          id: entry_id,
          version: nil,
          description: nil,
          config: config,
          signature_paths: [],
          open_receivers: [],
          owns_receivers: [],
          produces: [],
          consumes: [],
          block_as_methods: 0,
          heredoc_templates: 0,
          trait_registries: 0,
          type_node_resolvers: 0,
          hkt_registrations: 0,
          hkt_definitions: 0,
          protocol_contracts: 0,
          source_rbs_synthesizer: false,
          node_rule_types: [],
          dynamic_return_receivers: [],
          type_specifier_methods: [],
          load_error: error&.message || "plugin did not register or could not be matched to a registered class"
        }
      end

      # For each `signature_paths:` directory the plugin resolves
      # against its gem root, report the absolute path and a
      # quick `.rbs`-file count. The count is a sanity signal:
      # an empty bundle directory loads silently today but
      # contributes nothing.
      def signature_path_rows(plugin)
        plugin.signature_paths.map do |abs|
          {
            path: abs,
            exists: File.directory?(abs),
            rbs_files: rbs_file_count(abs)
          }
        end
      end

      def rbs_file_count(dir)
        return 0 unless File.directory?(dir)

        Dir.glob(File.join(dir, "**", "*.rbs")).size
      end

      def entry_gem_name(entry)
        case entry
        when String then entry
        when Hash
          string_keyed = entry.to_h { |k, v| [k.to_s, v] }
          (string_keyed["gem"] || string_keyed["id"]).to_s
        else entry.to_s
        end
      end

      def entry_id(entry)
        case entry
        when Hash
          string_keyed = entry.to_h { |k, v| [k.to_s, v] }
          string_keyed["id"]
        end
      end

      def entry_config(entry)
        case entry
        when Hash
          string_keyed = entry.to_h { |k, v| [k.to_s, v] }
          string_keyed["config"] || {}
        else {}
        end
      end

      # Build orphan-error rows for load errors whose `plugin_ref`
      # did not bind to any configured plugin entry (e.g. a
      # dependency-cycle naming a plugin we already accounted for
      # but reported alongside another). De-duplicates against
      # errors we already attached.
      def orphan_load_errors(registry, rows)
        attached_refs = rows.compact.flat_map { |row| [row[:gem], row[:id]].compact }.to_set
        unattached = registry.load_errors.reject { |error| attached_refs.include?(error.plugin_ref.to_s) }
        unattached.map do |error|
          {
            gem: error.plugin_ref.to_s,
            status: :load_error,
            id: nil,
            version: nil,
            description: nil,
            config: {},
            signature_paths: [],
            open_receivers: [], owns_receivers: [], produces: [], consumes: [],
            block_as_methods: 0, heredoc_templates: 0, trait_registries: 0,
            type_node_resolvers: 0,
            hkt_registrations: 0, hkt_definitions: 0,
            protocol_contracts: 0, source_rbs_synthesizer: false,
            node_rule_types: [], dynamic_return_receivers: [], type_specifier_methods: [],
            load_error: error.message
          }
        end
      end
    end
  end
end
