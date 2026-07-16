# frozen_string_literal: true

require "rigor/plugin"

# ADR-32 — bundled `rigor-rbs-inline` plugin.
#
# Synthesises RBS from project Ruby files that carry rbs-inline-shaped comments (`#: () -> T`, `# @rbs
# name: T`, `# @rbs return: T`, attribute `#:`, …) and contributes the result to the analysis environment
# through the `source_rbs_synthesizer:` manifest hook.
#
# By default (WD2) only files starting with the upstream `# rbs_inline: enabled` magic comment are
# processed; a host context can flip this off by setting `require_magic_comment: false` in the plugin
# config (WD10).
module Rigor
  module Plugin
    # The plugin gem requires `rbs/inline` at load time; without the upstream library the synthesizer can't
    # do its job. Wrapped in a begin/rescue so the analyzer still loads if the user activated this plugin
    # without installing the `rbs-inline` gem (loud-on-activation, fail-soft to no contribution).
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
      # Synthesizer callable invoked once per project Ruby source file by `Environment.for_project` at
      # env-build time. Returns the synthesised RBS source as a String, or `nil` when the file contributes
      # nothing (no magic comment in the default mode, empty annotation set, parse error per WD6).
      class Synthesizer
        # RDoc directive names that parse as a bare type alias, so `#:<name>:` is indistinguishable from an
        # rbs-inline `#: <type>` assertion to upstream's parser. See {#rbs_inline_annotation?}. Hyphenated
        # directives (`:call-seq:`) are absent because they do not parse as an alias name in the first place.
        RDOC_DIRECTIVES = %i[
          nodoc doc notnew stopdoc startdoc enddoc main title category section
          args yields method attr include toc
        ].to_set.freeze

        # @param require_magic_comment [Boolean] when `true` (the default, WD2), only files with
        #   `# rbs_inline: enabled` are processed, and upstream's opt-in semantics apply verbatim. When
        #   `false` (WD10 host-context override), the magic comment is not required and the file is
        #   processed only if it actually carries an annotation — see {#annotated?}.
        def initialize(require_magic_comment:)
          @require_magic_comment = require_magic_comment
          freeze
        end

        # Return value contract:
        # - `String` (non-empty)         → successful synthesis
        # - `nil`                        → no contribution
        # - `[:error, message_string]`   → parse failed, surface info diagnostic per ADR-32 WD6
        def call(source_file_path)
          return nil unless RBS_INLINE_AVAILABLE
          return nil unless File.file?(source_file_path)

          source = File.read(source_file_path)
          return nil if source.empty?

          result = ::Prism.parse(source)
          return nil if !@require_magic_comment && !annotated?(result)

          # `opt_in: true` is rbs-inline's "require the magic comment" mode (per upstream parser.rb:62).
          # The plugin's `require_magic_comment:` config knob maps directly onto it.
          parsed = ::RBS::Inline::Parser.parse(result, opt_in: @require_magic_comment)
          return nil if parsed.nil?

          uses, decls, rbs_decls = parsed
          rendered = ::RBS::Inline::Writer.write(uses, decls, rbs_decls)
          return nil if rendered.nil? || rendered.strip.empty?

          rendered
        rescue ::StandardError => e
          # WD6 fail-soft — surface a structured error tuple so the engine's `Environment.for_project` can
          # emit a `source-rbs-synthesis-failed` info diagnostic naming the file + the upstream error
          # message, without crashing analysis.
          [:error, "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"]
        end

        private

        # True when the file carries at least one rbs-inline annotation. Gates the magic-comment-free mode,
        # and is the difference between "honour annotations wherever they are" and "fabricate signatures for
        # code nobody annotated" — upstream's opt-out mode does the latter, emitting a full
        # `def f: (untyped x) -> untyped` skeleton for EVERY unannotated def. Rigor trusts an accepted
        # signature over body inference, so those skeletons would replace real inferred types with `untyped`:
        # measured on mail (zero annotations) as 26 → 42 diagnostics, i.e. the mode actively fought the
        # analysis on exactly the projects that write no annotations. The spec binds Rigor to treat
        # annotations as type sources "whenever present" (`overview.md` § "Compatibility hierarchy"); it does
        # not ask for untyped shadows of unannotated code.
        #
        # Detection delegates to upstream's own `AnnotationParser` rather than scanning for `#:` / `@rbs`
        # with a regexp: the annotation grammar is upstream's to define (ADR-32 WD3), and this keeps a doc
        # comment that merely mentions `@rbs`, or a URL containing `#:`, from opting a file in. A file with
        # the magic comment keeps upstream's semantics verbatim — the author opted that file in explicitly,
        # skeletons and all, which is what `rbs-inline --output` would generate for it.
        def annotated?(prism_result)
          ::RBS::Inline::AnnotationParser.parse(prism_result.comments).any? do |parsed|
            parsed.each_annotation.any? { |annotation| rbs_inline_annotation?(annotation) }
          end
        end

        # RDoc directives (`#:nodoc:`, `#:stopdoc:`, …) collide lexically with rbs-inline's `#: <type>` and
        # upstream's parser reads them as a type assertion of an alias named after the directive — it consumes
        # `nodoc` and drops the trailing colon. `class Foo #:nodoc:` is one of the most common comments in
        # Ruby, so without this every file carrying one would opt into synthesis: 61 of mail's files did,
        # which is why the annotation gate alone left it at 31 diagnostics instead of its true 26.
        #
        # The mis-parse is upstream's and worth reporting there; it is harmless in the OUTPUT (the directive
        # renders back as a plain `# :nodoc:` comment, not a bogus `nodoc` type), so this filter is needed
        # only at the gate — deciding whether the file carries a real annotation at all.
        def rbs_inline_annotation?(annotation)
          return true unless annotation.is_a?(::RBS::Inline::AST::Annotations::TypeAssertion)

          type = annotation.type
          return true unless type.is_a?(::RBS::Types::Alias) && type.name.namespace.empty?

          !RDOC_DIRECTIVES.include?(type.name.name)
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

      # Per-instance synthesizer — built from the manifest's default + the project's plugin config. The
      # manifest `source_rbs_synthesizer:` is nil at the class level so the registry sees the instance's
      # override (returned by `#manifest`, which `Plugin::Registry#source_rbs_synthesizers` consults via
      # `plugin.manifest.source_rbs_synthesizer`).
      #
      # ADR-32 WD10 — `require_magic_comment` defaults to `true`. Setting it to `false` in `.rigor.yml`
      # flips the synthesizer into "process every file" mode.
      def initialize(services:, config: {})
        super
        @require_magic_comment = config.fetch("require_magic_comment", true) ? true : false
        @synthesizer = Synthesizer.new(require_magic_comment: @require_magic_comment)
        # Build the per-instance manifest eagerly (before `freeze`) so the registry's repeated reads
        # return the same object and we don't need to mutate a frozen instance later.
        base = self.class.manifest
        @manifest_with_synth = build_manifest_with_synthesizer(base)
        freeze
      end

      attr_reader :synthesizer

      # Override the manifest-level `source_rbs_synthesizer:` (which is nil at the class level) with the
      # per-instance synthesizer built from the merged config. The registry reads this through
      # `plugin.manifest.source_rbs_synthesizer`.
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
