# frozen_string_literal: true

require "rigor/plugin"

# ADR-32 — bundled `rigor-rbs-inline` plugin.
#
# Synthesises RBS from project Ruby files that carry
# rbs-inline-shaped comments (`#: () -> T`, `# @rbs name: T`,
# `# @rbs return: T`, attribute `#:`, …) and contributes the
# result to the analysis environment through the
# `source_rbs_synthesizer:` manifest hook.
#
# By default (WD2) only files starting with the upstream
# `# rbs_inline: enabled` magic comment are processed; a host
# context can flip this off by setting `require_magic_comment:
# false` in the plugin config (WD10).
module Rigor
  module Plugin
    # The plugin gem requires `rbs/inline` at load time; without
    # the upstream library the synthesizer can't do its job.
    # Wrapped in a begin/rescue so the analyzer still loads if
    # the user activated this plugin without installing the
    # `rbs-inline` gem (loud-on-activation, fail-soft to no
    # contribution).
    begin
      require "prism"
      require "rbs/inline"
      RBS_INLINE_AVAILABLE = true
    rescue ::LoadError => e
      warn(
        "rigor-rbs-inline: failed to load `rbs/inline` " \
        "(#{e.message}). The plugin will load but contribute no " \
        "synthesised RBS. Install the `rbs-inline` gem to enable " \
        "inline-RBS comment ingestion."
      )
      RBS_INLINE_AVAILABLE = false
    end

    class RbsInline < Rigor::Plugin::Base
      # Synthesizer callable invoked once per project Ruby
      # source file by `Environment.for_project` at env-build
      # time. Returns the synthesised RBS source as a String,
      # or `nil` when the file contributes nothing (no magic
      # comment in the default mode, empty annotation set,
      # parse error per WD6).
      class Synthesizer
        # @param require_magic_comment [Boolean] when `true`
        #   (the default, WD2), only files with
        #   `# rbs_inline: enabled` at the top are processed.
        #   When `false` (WD10 host-context override), every
        #   file is treated as if it carried the magic comment.
        def initialize(require_magic_comment:)
          @require_magic_comment = require_magic_comment
          freeze
        end

        # Return value contract:
        # - `String` (non-empty)         → successful synthesis
        # - `nil`                        → no contribution
        # - `[:error, message_string]`   → parse failed, surface
        #   info diagnostic per ADR-32 WD6
        def call(source_file_path)
          return nil unless RBS_INLINE_AVAILABLE
          return nil unless File.file?(source_file_path)

          source = File.read(source_file_path)
          return nil if source.empty?

          result = ::Prism.parse(source)
          # `opt_in: true` is rbs-inline's "require the magic
          # comment" mode (per upstream parser.rb:62). The
          # plugin's `require_magic_comment:` config knob maps
          # directly onto it.
          parsed = ::RBS::Inline::Parser.parse(result, opt_in: @require_magic_comment)
          return nil if parsed.nil?

          uses, decls, rbs_decls = parsed
          rendered = ::RBS::Inline::Writer.write(uses, decls, rbs_decls)
          return nil if rendered.nil? || rendered.strip.empty?

          rendered
        rescue ::StandardError => e
          # WD6 fail-soft — surface a structured error tuple so
          # the engine's `Environment.for_project` can emit a
          # `source-rbs-synthesis-failed` info diagnostic
          # naming the file + the upstream error message,
          # without crashing analysis.
          [:error, "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"]
        end
      end

      manifest(
        id: "rbs-inline",
        version: "0.1.0",
        description: "Ingests rbs-inline-shaped comments " \
                     "(`# @rbs name: T`, `#: () -> T`, …) as RBS contributions.",
        config_schema: { "require_magic_comment" => :boolean },
        source_rbs_synthesizer: nil # set per-instance below
      )

      # Per-instance synthesizer — built from the manifest's
      # default + the project's plugin config. The manifest
      # `source_rbs_synthesizer:` is nil at the class level so
      # the registry sees the instance's override (returned by
      # `#manifest`, which `Plugin::Registry#source_rbs_synthesizers`
      # consults via `plugin.manifest.source_rbs_synthesizer`).
      #
      # ADR-32 WD10 — `require_magic_comment` defaults to
      # `true`. Setting it to `false` in `.rigor.yml` flips the
      # synthesizer into "process every file" mode.
      def initialize(services:, config: {})
        super
        @require_magic_comment = config.fetch("require_magic_comment", true) ? true : false
        @synthesizer = Synthesizer.new(require_magic_comment: @require_magic_comment)
        # Build the per-instance manifest eagerly (before
        # `freeze`) so the registry's repeated reads return
        # the same object and we don't need to mutate a
        # frozen instance later.
        base = self.class.manifest
        @manifest_with_synth = build_manifest_with_synthesizer(base)
        freeze
      end

      attr_reader :synthesizer

      # Override the manifest-level `source_rbs_synthesizer:`
      # (which is nil at the class level) with the per-instance
      # synthesizer built from the merged config. The registry
      # reads this through `plugin.manifest.source_rbs_synthesizer`.
      def manifest
        @manifest_with_synth
      end

      private

      def build_manifest_with_synthesizer(base)
        Rigor::Plugin::Manifest.new(
          id: base.id,
          version: base.version,
          description: base.description,
          config_schema: base.config_schema,
          produces: base.produces,
          consumes: base.consumes,
          owns_receivers: base.owns_receivers,
          open_receivers: base.open_receivers,
          type_node_resolvers: base.type_node_resolvers,
          block_as_methods: base.block_as_methods,
          heredoc_templates: base.heredoc_templates,
          trait_registries: base.trait_registries,
          external_files: base.external_files,
          hkt_registrations: base.hkt_registrations,
          hkt_definitions: base.hkt_definitions,
          signature_paths: base.signature_paths,
          protocol_contracts: base.protocol_contracts,
          source_rbs_synthesizer: @synthesizer
        )
      end
    end

    Rigor::Plugin.register(RbsInline)
  end
end
