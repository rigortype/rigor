# frozen_string_literal: true

require "rigor/plugin"
require_relative "rbs_inline/same_line_annotations"

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

        # The RBS annotation the synthesizer writes on every member whose type upstream DEFAULTED rather
        # than read off an annotation (issue #823). Its meaning is normative in
        # `docs/type-specification/rbs-extended.md`: the declaration states the member's presence and its
        # parameters, and says nothing about what it returns, so the engine infers the return from the body
        # instead of adopting the placeholder. `Rigor::RbsExtended.inferred_return?` is the reader.
        INFERRED_RETURN_ANNOTATION = "rigor:v1:inferred-return"

        # The RBS annotation the synthesizer writes on every member where upstream defaulted EVERY type
        # slot — every parameter and the return alike — because the author's comment block asserted nothing
        # about this member's own contract (issue #991). This is a strictly narrower condition than
        # {INFERRED_RETURN_ANNOTATION}: that one fires whenever the return alone defaulted, which is also
        # true of a member whose parameters WERE annotated (`# @rbs num: Float` with no `# @rbs return:`).
        # This annotation distinguishes "nobody said anything about this member" from "the return half was
        # left to inference" — the two collapse under return-only provenance, because no equivalent
        # per-parameter survivor exists to separate them (see {DEFAULTED_TYPE_NAME}), so this constant
        # exists precisely to carry that missing half. Its meaning is normative in
        # `docs/type-specification/rbs-extended.md`. `Rigor::RbsExtended.inferred_signature?` is the reader.
        INFERRED_SIGNATURE_ANNOTATION = "rigor:v1:inferred-signature"

        # The stand-in type handed to upstream's `Writer#default_type`, and the whole reason this plugin can
        # tell a defaulted type from an authored one. `RBS::Inline::Writer` substitutes `default_type`
        # wherever the author wrote nothing — `return_type || default_type` in `RubyDef#method_overloads`,
        # `attribute_type || default_type` in `RubyAttr#rbs` — and leaves an authored type alone. Rendering
        # with a distinctive stand-in therefore makes "the author did not write this" a fact in the output
        # rather than a guess about it: a member whose return renders as this name was defaulted, and one
        # that renders `untyped` was WRITTEN `untyped` by its author (`#: (String) -> untyped`), which is a
        # real contract and stays one.
        #
        # `default_type` is upstream's own public accessor for exactly this substitution, and `Writer.write`
        # yields the writer to configure it, so nothing here reaches into upstream internals. The stand-in
        # never survives into the contributed RBS — {#mark_inferred_returns} rewrites every occurrence back
        # to `untyped` — which is not cosmetic: an undeclared type alias makes `RBS::DefinitionBuilder` raise
        # `NoTypeFoundError` for the whole class, the same failure ADR-93 WD4's Finding 5 measured on
        # `#:nodoc:`.
        DEFAULTED_TYPE_NAME = :rigor__inline_defaulted

        private_constant :ECHOED_ANNOTATION, :DECLARATION_LINE, :COMMENT_LINE, :DEFAULTED_TYPE_NAME

        # @param require_magic_comment — when `false` (the default since ADR-93 WD1), the magic
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
          # Issue #998 — before the writer reads the annotation lists, so a same-line `%a{…} () -> T` renders
          # with its method type and its annotation both attached. See {SameLineAnnotations}.
          SameLineAnnotations.each_parsing_result(decls) { |comments| SameLineAnnotations.split!(comments) }
          rendered = mark_inferred_returns(render_with_defaulted_marker(uses, decls, rbs_decls))
          rendered = reattach_declaration_annotations(rendered)
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

        # Upstream's writer, told to substitute {DEFAULTED_TYPE_NAME} instead of `untyped` wherever the
        # author wrote no type. See that constant for why the distinction is worth a stand-in.
        def render_with_defaulted_marker(uses, decls, rbs_decls)
          marker = ::RBS::Types::Alias.new(
            name: ::RBS::TypeName.new(namespace: ::RBS::Namespace.empty, name: DEFAULTED_TYPE_NAME),
            args: [],
            location: nil
          )
          ::RBS::Inline::Writer.write(uses, decls, rbs_decls) { |writer| writer.default_type = marker }
        end

        # Issue #823 — the sibling rule. ADR-93 WD1 gates synthesis on a file that carries an annotation;
        # inside such a file upstream emits a full `def f: (untyped x) -> untyped` skeleton for every
        # unannotated `def`, and Rigor trusts an accepted signature over body inference. So one `# @rbs`
        # anywhere in a file used to retype every OTHER method in it to `untyped` — the same mechanism
        # ADR-93 WD1 measured project-wide before the file gate landed (mail 26 → 42 diagnostics), just
        # scoped to the annotated file. An annotation on one method must not change the typing of its
        # siblings in either direction.
        #
        # The skeleton is kept — that is what PR #779's member-level drop got wrong, because a partially
        # declared class reads to RBS as a fully declared one (32 `call.undefined-method` and 12
        # `call.wrong-arity` on `new`, and 44 classes to `Dynamic[top]` behind cross-file references that
        # stopped resolving). What changes is what the skeleton CLAIMS: a defaulted type slot is rewritten
        # back to `untyped` and its member is annotated {INFERRED_RETURN_ANNOTATION}, so the declaration
        # keeps the class's full method surface, `new`'s arity and every cross-file name, and states nothing
        # about the return. The engine reads the annotation in `RbsDispatch` and falls through to the same
        # body-inference tier an undeclared method takes.
        #
        # A member additionally carries {INFERRED_SIGNATURE_ANNOTATION} when EVERY type slot on it —
        # not only the return — defaulted: a fully bare `def`, or one whose only annotation lives on a
        # sibling member the file also happens to carry. A member with a parameter annotated (`# @rbs num:
        # Float`) but no `# @rbs return:` still gets {INFERRED_RETURN_ANNOTATION} (the return did default),
        # but NOT this one — the author asserted something about the member, just not its return. Issue
        # #991's `call.wrong-arity` reads this one rather than the return-only annotation, because the
        # arity question is about the parameter list, and the parameter list is exactly what tells the two
        # cases apart.
        #
        # Two properties make the rewrite safe rather than clever:
        #
        # - the stand-in is a token this plugin injected, so replacing it is exact — it can only appear
        #   where upstream substituted it (a comment echoing the same word would merely read `untyped`);
        # - the lines to annotate come from `RBS::Parser` reading the writer's own output, not from a
        #   pattern over it, and the replacement is length-preserving per line, so the parser's line numbers
        #   still address the same members after it.
        #
        # Marking is best-effort and the rewrite is not: if the probe parse is skipped or fails, the file
        # still ships with today's `untyped` skeleton rather than an unresolvable alias (see
        # {DEFAULTED_TYPE_NAME}). That asymmetry is why the encoding guard is shaped the way it is. Invalid
        # UTF-8 does not reach here today — the RDoc-directive scan above raises on it first, and {#call}'s
        # rescue routes the file to WD6 — but the guarded parse is the one `RbsLoader.add_virtual_rbs`
        # documents as HANG-prone on pre-4.1 rbs lexers, and a hang escapes every rescue there is. So the
        # probe is skipped for a byte sequence it could hang on, while the substitution runs over bytes and
        # therefore always completes.
        def mark_inferred_returns(rendered)
          return rendered if rendered.nil? || !rendered.b.include?(DEFAULTED_TYPE_NAME.to_s)

          return_lines, signature_lines =
            rendered.valid_encoding? ? defaulted_member_lines(rendered) : [Set.new, Set.new]
          scrubbed = rendered.b.gsub(DEFAULTED_TYPE_NAME.to_s, "untyped").force_encoding(rendered.encoding)
          return scrubbed if return_lines.empty?

          scrubbed.lines.each_with_index.flat_map do |line, index|
            line_number = index + 1
            next line unless return_lines.include?(line_number)

            indent = line[/\A[ \t]*/]
            annotations = ["#{indent}%a{#{INFERRED_RETURN_ANNOTATION}}\n"]
            annotations << "#{indent}%a{#{INFERRED_SIGNATURE_ANNOTATION}}\n" if signature_lines.include?(line_number)
            [*annotations, line]
          end.join
        end

        # The 1-based lines of every member in `rendered` whose return type (or, for an attribute, whose
        # type) is the defaulted stand-in — and, of those, the subset where EVERY type slot on the member
        # defaulted, not only the return. A member's `location.start_line` is the line its `def` /
        # `attr_*` keyword sits on, which is where the annotation has to go. Returns `[return_lines,
        # signature_lines]`; `signature_lines` is always a subset of `return_lines`, since a member cannot
        # have every slot defaulted without its return being one of them.
        def defaulted_member_lines(rendered)
          buffer = ::RBS::Buffer.new(name: "(rigor: inline defaulted-type probe)", content: rendered)
          _, _directives, decls = ::RBS::Parser.parse_signature(buffer)
          collect_defaulted_member_lines(decls, Set.new, Set.new)
        rescue ::StandardError
          # The writer's own output failing to parse is a condition the loader already handles (ADR-32 WD6
          # fail-soft drops the entry). Declining to mark here keeps that the only failure.
          [Set.new, Set.new]
        end

        def collect_defaulted_member_lines(nodes, return_lines, signature_lines)
          nodes.each do |node|
            next unless node.respond_to?(:members)

            node.members.each do |member|
              classify_defaulted_member(member, return_lines, signature_lines)
            end
            collect_defaulted_member_lines(
              node.members.grep(::RBS::AST::Declarations::Base), return_lines, signature_lines
            )
          end
          [return_lines, signature_lines]
        end

        def classify_defaulted_member(member, return_lines, signature_lines)
          case member
          when ::RBS::AST::Members::MethodDefinition
            return unless member.overloads.any? { |o| defaulted_type?(o.method_type.type.return_type) }

            line = member.location&.start_line
            return if line.nil?

            return_lines << line
            signature_lines << line if member.overloads.all? { |o| fully_defaulted_overload?(o) }
          when ::RBS::AST::Members::Attribute
            return unless defaulted_type?(member.type)

            line = member.location&.start_line
            return if line.nil?

            # An attribute has exactly one type slot (the value type, shared by its reader and writer
            # overloads), so "the type defaulted" and "every type slot defaulted" are the same fact.
            return_lines << line
            signature_lines << line
          end
        end

        # True when every parameter type and the return type of `overload` — everything
        # `RBS::Types::Function#each_type` yields — is the defaulted stand-in, i.e. the author's comment
        # block asserted nothing about this overload's own contract. Block-type provenance is
        # deliberately not part of this: a block parameter's shape does not bear on the positional arity
        # #991 exists to check, and upstream defaults it independently of the parameter list either way.
        def fully_defaulted_overload?(overload)
          function = overload.method_type.type
          return false unless function.respond_to?(:each_type)

          function.each_type.all? { |type| defaulted_type?(type) }
        end

        def defaulted_type?(type)
          type.is_a?(::RBS::Types::Alias) && type.name.name == DEFAULTED_TYPE_NAME
        end

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
        # Five cases today:
        #
        # - `module-self`, where the two inline-RBS dialects disagree on spelling. rbs's own `docs/inline.md`
        #   documents `# @rbs module-self: Foo`; the rbs-inline gem's grammar is `# @rbs module-self Foo`,
        #   without the colon. Handed the colon form the gem still builds a `ModuleSelf` annotation but
        #   extracts no types from it, so an empty `self_types` on a parsed annotation is a precise signature
        #   for "the author asked for a constraint we did not apply". Measured both ways in
        #   `docs/notes/20260730-inline-rbs-parser-grammar-diff.md`.
        # - a `#:` line whose type does not parse (issue #997). Upstream's own tolerant parse
        #   ({#parse_type_method_type} in its `annotation_parser.rb`) never raises on this: it consumes the
        #   rest of the line into a `SyntaxErrorAssertion` and moves on, so nothing upstream ever surfaces
        #   the failure. Measured at 568138c2: `#: (finite-float) -> String` above a `def` synthesized no
        #   signature for it AT ALL, and `rigor check` on the file reported nothing beyond an unrelated
        #   `rbs.coverage.missing-gem` info — the annotation was indistinguishable from one never written,
        #   which ADR-93's "an inline annotation is a live contract" forbids.
        # - an `# @rbs %a{…}` line whose text after the annotations is not a method type (issue #998). The
        #   gem's `@rbs %a{}` rule lexes the annotations and ignores the rest of the line, so
        #   `# @rbs %a{pure} (finite-float) -> String` keeps `%a{pure}` and discards the signature beside it
        #   without a word. A remainder that IS a method type is not reported, because
        #   {SameLineAnnotations.split!} has already made it bind — the notice is for what that repair
        #   could not read.
        # - an `# @rbs name: T` parameter (or local-variable) annotation whose `T` does not parse (issue
        #   #1019, row H). The gem's grammar makes the colon-and-type optional — {#parse_var_decl} always
        #   builds a `VarType`, even when `parse_type` fell through — so a malformed type leaves `name`
        #   present and `type` `nil` rather than raising: `# @rbs n: Integer[1..10]` names `n` and leaves its
        #   type unset. `Writer#default_type` then fills the empty slot the same way an UNANNOTATED parameter
        #   is filled, so `VarType#type.nil?` is indistinguishable downstream from "the author wrote nothing"
        #   without this check — the same silent-drop shape #997 closed for `#:` lines and `return:`, now
        #   closed for `name:`.
        # - an `@rbs`-prefixed comment paragraph whose body is not one of the gem's known annotation shapes
        #   (issue #1019, row B). {RBS::Inline::AnnotationParser#annotation_comment?} matches a `\b` word
        #   boundary right after `@rbs`, so `# @rbs-ext …` is inside its net — the gem treats it as an `@rbs`
        #   annotation attempt — but {RBS::Inline::AnnotationParser#parse_annotation}'s `case` has no branch
        #   for what follows `-ext`, falls through with no `else`, and returns `nil`. `AnnotationParser#parse`
        #   then folds the whole paragraph back into a `CommentLines` — the SAME class an ordinary comment
        #   parses to — so nothing distinguishes "the gem tried to read this as `@rbs` and failed" from
        #   "this was never meant to be one" except the marker the gem itself keyed on. {SameLineAnnotations::
        #   RBS_MARKER} already carries that exact marker (documented there as "the `@rbs` marker as the
        #   gem's `annotation_comment?` detects it"), reused here rather than duplicated, so a `CommentLines`
        #   paragraph is only reported when the gem's own detector would have called it an `@rbs` attempt.
        #
        # The list is repaired by {SameLineAnnotations.split!} first, exactly as the synthesis path repairs
        # its own, so a valid same-line `#: %a{…} () -> T` is not reported as a `#:` line that failed to
        # parse: it did not fail, it binds.
        #
        # Deliberately narrow otherwise. A construct the gem's parser REJECTS already routes through WD6's
        # error path, and one it never recognised at all is upstream's grammar to define (WD3) — guessing at
        # those would make this a lint on comment prose, which is exactly the false-positive cost ADR-5 ranks
        # first. `SyntaxErrorAssertion` is neither: the gem's OWN parser recognised the `#:` shape and
        # positively flagged its payload as unparseable, so reporting it is naming a fact rbs-inline already
        # computed, not guessing at one. The row-B check is the same kind of fact, read off the gem's own
        # marker rather than a fact rbs-inline names with a dedicated AST class — nothing else in the grammar
        # collapses a recognised-but-unparseable paragraph into ordinary prose.
        def unhonoured_annotations(prism_result)
          ::RBS::Inline::AnnotationParser.parse(prism_result.comments).flat_map do |parsed|
            repaired = SameLineAnnotations.split!(parsed)
            unrecognised_tag_notices(repaired) + repaired.each_annotation.filter_map do |annotation|
              case annotation
              when ::RBS::Inline::AST::Annotations::ModuleSelf
                next if annotation.self_types.any?

                "`@rbs module-self` contributed no self-type constraint. Rigor reads the " \
                  "`# @rbs module-self Foo` spelling; `# @rbs module-self: Foo` (the spelling in rbs's own " \
                  "inline documentation) is not honoured here."
              when ::RBS::Inline::AST::Annotations::SyntaxErrorAssertion
                syntax_error_assertion_notice(annotation)
              when ::RBS::Inline::AST::Annotations::RBSAnnotation
                dropped_remainder_notice(annotation)
              when ::RBS::Inline::AST::Annotations::VarType
                var_type_notice(annotation)
              end
            end
          end.uniq
        end

        # Issue #997 — the line comes off the annotation's OWN `Prism::Comment` location, not the
        # synthesized RBS buffer: unlike {Environment::RbsLoader#unresolved_type_name_detail}'s position,
        # this one is read straight from the `.rb` file this synthesis call is fresh over (the per-file
        # synthesizer cache is content-keyed, so a changed file simply misses rather than replaying a stale
        # line), so it is the real line the author wrote, not an approximation.
        def syntax_error_assertion_notice(annotation)
          line = annotation.source.comments.first&.location&.start_line
          position = line ? " on line #{line}" : ""
          "a `#:` annotation#{position} did not parse as an RBS method type or type " \
            "(`#{annotation.error_string}`) and was DROPPED — the method types as if the annotation had " \
            "never been written, not merely as if its type were wrong. Fix the RBS syntax to restore it."
        end

        # Issue #998 — the line is read off the annotation's own comment, as in {#syntax_error_assertion_notice}.
        def dropped_remainder_notice(annotation)
          remainder = SameLineAnnotations.dropped_remainder(annotation)
          return nil if remainder.nil?

          line = annotation.source.comments.first&.location&.start_line
          position = line ? " on line #{line}" : ""
          "the text after the `%a{…}` annotation#{position} (`#{remainder}`) did not parse as an RBS method " \
            "type and was DROPPED — the annotation is kept, but the method types as if no signature had been " \
            "written beside it. Fix the RBS syntax to restore it."
        end

        # Issue #1019, row H — a `# @rbs name: T` whose `T` the gem's `parse_type` could not build, read off
        # {RBS::Inline::AST::Annotations::VarType#type} being `nil` rather than off any pattern over the
        # comment text. Silent otherwise: {Writer#default_type} fills the slot exactly as it fills a
        # parameter nobody annotated, so `(untyped n)` does not distinguish "wrote nothing" from "wrote a
        # type RBS could not parse". `raw` is `nil` (and the notice withheld) for the colon-less `# @rbs
        # name` shorthand — the grammar accepts it too, but with no text to name as the dropped type it is a
        # bare mention, not a failed assertion.
        def var_type_notice(annotation)
          return nil if annotation.type

          raw = annotation.source.string[/#{Regexp.escape(annotation.name.to_s)}\s*:\s*(.+)\z/, 1]&.strip
          return nil if raw.nil? || raw.empty?

          line = annotation.source.comments.first&.location&.start_line
          position = line ? " on line #{line}" : ""
          "a `# @rbs #{annotation.name}:` annotation#{position} (`#{raw}`) did not parse as an RBS type " \
            "and was DROPPED — the parameter types as `untyped`, not merely as if its type were wrong. If " \
            "`#{raw}` is a Rigor refinement, write it as an `%a{rigor:v1:param: #{annotation.name} is " \
            "#{raw}}` annotation beside the plain RBS type instead — see " \
            "docs/manual/16-rbs-extended-annotations.md — to restore type coverage."
        end

        # Issue #1019, row B — an `@rbs`-prefixed comment paragraph the gem's OWN detector
        # ({RBS::Inline::AnnotationParser#annotation_comment?}) called an `@rbs` annotation attempt, that
        # `#parse_annotation`'s `case` had no branch for. `# @rbs-ext return: non-empty-string` is the case
        # in point: `annotation_comment?`'s `/\A#(\s*)@rbs(\b|!)/` matches the `\b` word boundary between
        # `s` and `-`, so the gem tries to read it as `@rbs`, fails, and folds it back into a `CommentLines`
        # — the same class a `# rigor: …` or `# @extrbs …` paragraph parses to, which never claimed to be
        # `@rbs` and must stay silent (row X / row C). {SameLineAnnotations::RBS_MARKER} already carries the
        # gem's own marker, so matching it here is reading the SAME fact the gem's detector computed, not
        # inventing a new one — see {#unhonoured_annotations}'s row-B paragraph for why that is not the
        # "regexp lint on comment prose" WD12 otherwise declines to run.
        def unrecognised_tag_notices(parsing_result)
          parsing_result.annotations.grep(::RBS::Inline::AST::CommentLines).filter_map do |lines|
            first_line = lines.string.each_line.first.to_s.strip
            next unless SameLineAnnotations::RBS_MARKER.match?(first_line)

            line = lines.comments.first&.location&.start_line
            position = line ? " on line #{line}" : ""
            "a comment#{position} (`##{first_line}`) opens with the `@rbs` marker but its body did not " \
              "parse as a recognised `@rbs` annotation, so the whole line was DROPPED — this is not a " \
              "recognised tag, and nothing on it was applied. Use one of the documented `# @rbs` forms " \
              "(`name: T`, `return: T`, `module-self T`, …), or rename the tag so it does not start with " \
              "`@rbs`, to avoid this notice."
          end
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
