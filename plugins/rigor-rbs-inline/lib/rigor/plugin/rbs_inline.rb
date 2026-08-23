# frozen_string_literal: true

require "rigor/plugin"

# ADR-32 — bundled `rigor-rbs-inline` plugin.
#
# Synthesises RBS from project Ruby files that carry rbs-inline-shaped comments (`#: () -> T`, `# @rbs
# name: T`, `# @rbs return: T`, attribute `#:`, …) and contributes the result to the analysis environment
# through the `source_rbs_synthesizer:` manifest hook.
#
# Since ADR-93 WD1 the default is `require_magic_comment: false`: a file is processed whenever it actually
# carries an annotation (see {Synthesizer#annotated?}), with only the upstream `# rbs_inline: disabled`
# directive opting a file out. Set `require_magic_comment: true` to restore the old ADR-32 WD2 gate that
# processed only files opening with `# rbs_inline: enabled`.
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
        # An RDoc directive comment: `#:` followed by a bare word (RDoc allows a hyphen, as in `:call-seq:`)
        # and a closing colon. RDoc predates rbs-inline by about two decades and `#:<name>:` is
        # indistinguishable from an rbs-inline `#: <type>` assertion to upstream's parser, which reads the
        # directive name as a type alias — `def f #:nodoc:` becomes `def f: () -> nodoc`, a type nothing
        # declares (upstream issue: https://github.com/soutaro/rbs-inline/issues/248).
        #
        # Matching on shape rather than a name list covers all 17 directives the Ruby docs list
        # (https://docs.ruby-lang.org/ja/latest/library/rdoc.html) with nothing to maintain, and none of
        # `#: () -> void`, `#: String`, `#:Integer`, `#: bool`, `#:my_alias`, `#: { name: String }`,
        # `#: (name: String) -> void`, `#: Integer?`, `#[Integer]` or `# @rbs x: String` matches it: a valid
        # RBS type never starts with a bare lowercase word that is immediately closed by a colon. Only the
        # space-free spelling is affected; `# :nodoc:` never reaches upstream's annotation grammar.
        RDOC_DIRECTIVE_COMMENT = /\A#:[a-z_][\w-]*:/

        # An `%a{…}` the author wrote above a `class` / `module`, as upstream's writer echoes it: an ordinary
        # comment, because the writer emits no annotation on a declaration
        # ([#452](https://github.com/rigortype/rigor/issues/452)).
        ECHOED_ANNOTATION = /\A\s*#\s*@rbs\s+(%a\{[^}]*\})\s*\z/

        # The declaration the pending annotations belong to. `class`/`module` and the whitespace after the
        # keyword, so `class_eval` is not one and the indentation to re-emit at is captured.
        DECLARATION_LINE = /\A(\s*)(?:class|module)\s/

        COMMENT_LINE = /\A\s*#/

        private_constant :ECHOED_ANNOTATION, :DECLARATION_LINE, :COMMENT_LINE

        # @param require_magic_comment [Boolean] when `false` (the default since ADR-93 WD1), the magic
        #   comment is not required and the file is processed only if it actually carries an annotation — see
        #   {#annotated?}. When `true` (the old ADR-32 WD2 gate), only files opening with
        #   `# rbs_inline: enabled` are processed, and upstream's opt-in semantics apply verbatim.
        def initialize(require_magic_comment:)
          @require_magic_comment = require_magic_comment
          freeze
        end

        # Return value contract:
        # - `String` (non-empty)          → successful synthesis
        # - `nil`                         → no contribution
        # - `[:error, message_string]`    → parse failed, surface info diagnostic per ADR-32 WD6
        # - `[:ok, source, [message, …]]` → synthesis succeeded, but an annotation was parsed and NOT
        #                                   honoured; surface info diagnostics per ADR-32 WD12
        def call(source_file_path)
          return nil unless RBS_INLINE_AVAILABLE
          return nil unless File.file?(source_file_path)

          source = File.read(source_file_path)
          return nil if source.empty?

          result = ::Prism.parse(source)
          _, result = neutralize_rdoc_directives(source, result)
          return nil if !@require_magic_comment && !annotated?(result)

          # `opt_in: true` is rbs-inline's "require the magic comment" mode (per upstream parser.rb:62).
          # The plugin's `require_magic_comment:` config knob maps directly onto it.
          parsed = ::RBS::Inline::Parser.parse(result, opt_in: @require_magic_comment)
          return nil if parsed.nil?

          uses, decls, rbs_decls = parsed
          rendered = reattach_declaration_annotations(::RBS::Inline::Writer.write(uses, decls, rbs_decls))
          return nil if rendered.nil? || rendered.strip.empty?

          notices = unhonoured_annotations(result)
          notices.empty? ? rendered : [:ok, rendered, notices]
        rescue ::StandardError => e
          # WD6 fail-soft — surface a structured error tuple so the engine's `Environment.for_project` can
          # emit a `source-rbs-synthesis-failed` info diagnostic naming the file + the upstream error
          # message, without crashing analysis.
          [:error, "#{e.class}: #{e.message.to_s.lines.first.to_s.strip}"]
        end

        private

        # Re-attaches a class- or module-level `%a{…}` that upstream's writer dropped (#452).
        #
        # `RBS::Inline::Writer` emits a member's annotations as real annotation lines and a *declaration's*
        # as nothing at all — it echoes the author's comment block above `class Foo` and stops there. So the
        # cheapest bound in the feature, one line above a class, reached the envelope reader as a comment:
        # no bound, no diagnostic, and a clean run that had checked nothing. The `.rbs` lane, writing the
        # same `%a{pure}` above the same `class`, worked. Both lanes now answer the same.
        #
        # The rewrite reads only what the writer itself emitted, in one pass, and is deliberately literal:
        # an annotation the author spelled in a comment block that the writer echoed is re-emitted, at the
        # declaration's own indentation, on the line the RBS grammar wants it on. Three properties make that
        # safe rather than clever:
        #
        # - a comment block is echoed **only when its member is emitted**, so a detached annotation (one a
        #   blank line separates from the declaration, which upstream drops) is never echoed and so never
        #   re-attached — the two lanes agree about that too;
        # - any non-comment line clears the pending set, so a member's own annotation — which the writer
        #   *does* emit, on the line between the echo and the `def` — ends the run before a declaration can
        #   claim it, and no annotation is ever attached twice;
        # - the same property makes this forward-compatible: if upstream some day emits the declaration
        #   annotation itself, that line clears the pending set and this contributes nothing.
        def reattach_declaration_annotations(rendered)
          return rendered if rendered.nil? || !rendered.include?("%a{")

          pending = []
          rendered.lines.flat_map do |line|
            if (annotation = ECHOED_ANNOTATION.match(line))
              pending << annotation[1]
              line
            elsif COMMENT_LINE.match?(line)
              line
            elsif (declaration = DECLARATION_LINE.match(line)) && !pending.empty?
              emitted = pending.map { |spelling| "#{declaration[1]}#{spelling}\n" } << line
              pending = []
              emitted
            else
              pending = []
              line
            end
          end.join
        end

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
          ::RBS::Inline::AnnotationParser.parse(prism_result.comments)
                                         .any? { |parsed| parsed.each_annotation.any? }
        end

        # ADR-32 WD12 — annotations upstream's parser ACCEPTS and its writer then contributes nothing from.
        # These are invisible without a report: synthesis succeeds, and the annotation comment is even echoed
        # into the generated RBS, so the omission shows up neither in the output nor at runtime.
        #
        # The one case today is `module-self`, where the two inline-RBS dialects disagree on spelling. rbs's
        # own `docs/inline.md` documents `# @rbs module-self: Foo`; the rbs-inline gem's grammar is
        # `# @rbs module-self Foo`, without the colon. Handed the colon form the gem still builds a
        # `ModuleSelf` annotation but extracts no types from it, so an empty `self_types` on a parsed
        # annotation is a precise signature for "the author asked for a constraint we did not apply".
        # Measured both ways in `docs/notes/20260730-inline-rbs-parser-grammar-diff.md`.
        #
        # Deliberately narrow. A construct the gem's parser REJECTS already routes through WD6's error path,
        # and one it never recognised at all is upstream's grammar to define (WD3) — guessing at those would
        # make this a lint on comment prose, which is exactly the false-positive cost ADR-5 ranks first.
        def unhonoured_annotations(prism_result)
          ::RBS::Inline::AnnotationParser.parse(prism_result.comments).flat_map do |parsed|
            parsed.each_annotation.filter_map do |annotation|
              next unless annotation.is_a?(::RBS::Inline::AST::Annotations::ModuleSelf)
              next unless annotation.self_types.empty?

              "`@rbs module-self` contributed no self-type constraint. Rigor reads the " \
                "`# @rbs module-self Foo` spelling; `# @rbs module-self: Foo` (the spelling in rbs's own " \
                "inline documentation) is not honoured here."
            end
          end.uniq
        end

        # Rewrite every RDoc directive comment to its spaced spelling (`#:nodoc:` -> `# :nodoc:`) so
        # upstream's annotation grammar never sees it, and re-parse. Two reasons this happens here rather
        # than in {#annotated?}: the directive must not gate a file in, AND it must not reach the synthesis,
        # because one mis-parsed directive takes the whole class down with it. `def f #:nodoc:` renders as
        # `def f: (untyped x) -> nodoc`; `nodoc` resolves to nothing, `RBS::DefinitionBuilder` raises
        # `NoTypeFoundError` for the class, and every real annotation in that class is silently lost —
        # measured on a class whose `#: (String) -> Integer` method fell back to body inference because a
        # sibling method carried `#:nodoc:`. `fileutils.rb` alone carries 29 of these.
        #
        # The rewrite touches comment text only, so it cannot change what Ruby does; it shifts columns
        # within the comment, which nothing downstream reads (the synthesized RBS is fresh text with its own
        # buffer). Prism decides what is a comment, so a `#:nodoc:` inside a string literal stays put. Files
        # without a directive re-parse nothing.
        def neutralize_rdoc_directives(source, prism_result)
          offsets = prism_result.comments.filter_map do |comment|
            location = comment.location
            # `start_character_offset`, not `start_offset`: the latter counts BYTES while `String#insert`
            # indexes CHARACTERS, so on a file with any multi-byte content the space lands mid-word and
            # rewrites `#:nodoc:` to `#:n odoc:` — still a directive to upstream, and now a corrupted one.
            location.start_character_offset if RDOC_DIRECTIVE_COMMENT.match?(location.slice)
          end
          return [source, prism_result] if offsets.empty?

          # Back to front, so each insertion leaves the earlier offsets valid.
          rewritten = offsets.sort.reverse.inject(source.dup) { |acc, offset| acc.insert(offset + 1, " ") }
          [rewritten, ::Prism.parse(rewritten)]
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
      # ADR-93 WD1 — `require_magic_comment` defaults to `false`: annotations are official type sources
      # "always parsed whenever present" per the binding spec (overview.md § Compatibility hierarchy), so
      # a file is processed when it actually carries an annotation, with the magic comment not required.
      # The magic-comment-free mode is annotation-presence-gated (see {Synthesizer#annotated?}), so an
      # unannotated file contributes nothing and the flip cannot regress it. Set `require_magic_comment:
      # true` in `.rigor.yml` to restore the ADR-32 opt-in behaviour; `# rbs_inline: disabled` remains the
      # per-file opt-out either way (honoured by upstream unconditionally).
      def initialize(services:, config: {})
        super
        @require_magic_comment = config.fetch("require_magic_comment", false) ? true : false
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
