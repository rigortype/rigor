# frozen_string_literal: true

require "strscan"

module Rigor
  module Plugin
    class RbsInline < Base
      # Issue #998 — the two same-line `%a{}` spellings rbs's built-in `RBS::InlineParser` and Steep's inline
      # mode accept, repaired into the shape the `rbs-inline` gem's writer honours:
      #
      # - `# @rbs %a{…} () -> String` — the gem's `@rbs %a{}` rule lexes the annotations and stops, so the
      #   method type after them is discarded and the method renders `() -> untyped`;
      # - `#: %a{…} () -> String` — the gem hands the whole payload to `RBS::Parser.parse_method_type`, which
      #   has no annotation prefix, so the line becomes a `SyntaxErrorAssertion` and nothing of it survives.
      #
      # Both were silent (ADR-32 WD12), and the second reached users as #997's "did not parse … DROPPED"
      # notice on input that is valid RBS for the other two readers.
      #
      # This is a post-parse repair of the gem's annotation list, not a rewrite of the Ruby source. A source
      # rewrite would have to put the annotation and the method type on two comment lines — the gem has no
      # one-line spelling for the pair, which is the defect — and inserting a line moves every later line,
      # including the ones a `#:` notice reports and the one a `def` uses to find its comment block.
      #
      # The repair is exact rather than heuristic because every step is the gem's own reading:
      #
      # - the leading `%a{…}` spellings are delimited by the gem's own `Tokenizer`, the lexer that already
      #   accepts them in the own-line form, so what counts as an annotation cannot drift from upstream;
      # - each half is re-read by the gem's own `AnnotationParser` as the comment the author would have written
      #   in the own-line form (`# @rbs %a{…}`, then `# @rbs () -> String` or `#: () -> String`), on the same
      #   line and column, so the replacement annotations are indistinguishable from ones upstream built;
      # - the split lands only when the remainder re-reads as a well-formed method type. Anything else keeps
      #   the gem's original annotation untouched, so a genuinely malformed line still reaches the WD12
      #   notices, and a split can never trade one silent loss for another.
      module SameLineAnnotations
        module_function

        # The `@rbs` marker as the gem's `annotation_comment?` detects it, with the whitespace before it.
        RBS_MARKER = /\A\s*@rbs\b/

        # Replaces, in `parsing_result.annotations`, every same-line form that splits cleanly with the
        # annotation and the method type it spells. Idempotent: a repaired list has no same-line form left.
        def split!(parsing_result)
          return parsing_result unless parsing_result.is_a?(::RBS::Inline::AnnotationParser::ParsingResult)

          parsing_result.annotations.replace(parsing_result.annotations.flat_map { |annotation| expand(annotation) })
          parsing_result
        end

        # Every `ParsingResult` a parsed declaration tree holds, which are the objects the writer reads.
        def each_parsing_result(nodes, &)
          nodes.each do |node|
            comments = node.respond_to?(:comments) ? node.comments : nil
            yield comments if comments.is_a?(::RBS::Inline::AnnotationParser::ParsingResult)
            each_parsing_result(node.members, &) if node.respond_to?(:members)
          end
        end

        # The text an `@rbs %a{…}` line carries after its annotations that the gem discarded — `nil` when
        # there is none. Call it on an annotation {.split!} has already seen: a remainder that survives the
        # split is one that did not read as a method type.
        def dropped_remainder(annotation)
          return nil unless annotation.is_a?(::RBS::Inline::AST::Annotations::RBSAnnotation)

          parts = same_line_parts(annotation)
          parts && parts[2].strip
        end

        def expand(annotation)
          parts = same_line_parts(annotation)
          return [annotation] if parts.nil?

          prefix, spellings, rest = parts
          method_type = reparse(annotation, "##{prefix}#{rest}")
          return [annotation] unless well_formed_method_type?(method_type)

          # Re-read even when `annotation` already is the `@rbs %a{}` carrier: the original still spans the
          # method type in its source, and {.dropped_remainder} reads exactly that to report a failed split.
          carrier = reparse(annotation, "# @rbs #{spellings.join(' ')}")
          return [annotation] unless carrier.is_a?(::RBS::Inline::AST::Annotations::RBSAnnotation)

          [carrier, method_type]
        end

        # `[prefix, spellings, rest]` for an annotation whose payload opens with one or more `%a{…}` and
        # continues with something else, or `nil`. `prefix` is the marker as written (`" @rbs"` or `":"`),
        # so the re-read keeps the gem's continuation offset for a multi-line comment block.
        def same_line_parts(annotation)
          # `annotations` also holds the `CommentLines` of plain prose, which has no `source` to read.
          prefix =
            case annotation
            when ::RBS::Inline::AST::Annotations::RBSAnnotation
              annotation.source.string[RBS_MARKER]
            when ::RBS::Inline::AST::Annotations::SyntaxErrorAssertion
              ":" if annotation.source.string.start_with?(":")
            end
          return nil if prefix.nil?

          spellings, rest = leading_annotations(annotation.source.string.delete_prefix(prefix))
          return nil if spellings.empty? || rest.strip.empty?

          [prefix, spellings, rest]
        end

        # The `%a{…}` tokens the gem's tokenizer reads at the head of `body`, and the unread text after them.
        def leading_annotations(body)
          tokenizer = ::RBS::Inline::AnnotationParser::Tokenizer.new(StringScanner.new(body))
          trivia = ::RBS::Inline::AST::Tree.new(:rigor_same_line_annotations)
          tokenizer.advance(trivia)
          tokenizer.advance(trivia)

          spellings = []
          while tokenizer.type?(::RBS::Inline::AnnotationParser::Tokens::T_ANNOTATION)
            spellings << tokenizer.lookahead1[1]
            tokenizer.advance(trivia)
          end
          [spellings, tokenizer.rest]
        end

        # Reads `comment_text` through the gem's `AnnotationParser` as if it stood where `annotation`'s comment
        # block does — same first line, same column, continuation lines re-prefixed with the `#` that
        # `CommentLines#string` strips — and returns the one annotation it yields, or `nil`.
        def reparse(annotation, comment_text)
          location = annotation.source.comments.first&.location
          return nil if location.nil?

          indent = " " * location.start_column
          padding = "\n" * (location.start_line - 1)
          source = "#{padding}#{indent}#{comment_text.gsub("\n") { "\n#{indent}#" }}\n"
          results = ::RBS::Inline::AnnotationParser.parse(::Prism.parse(source).comments)
          return nil unless results.size == 1

          annotations = results.first.annotations
          annotations.size == 1 && annotations.first.is_a?(::RBS::Inline::AST::Annotations::Base) ? annotations.first : nil
        end

        def well_formed_method_type?(annotation)
          case annotation
          when ::RBS::Inline::AST::Annotations::MethodTypeAssertion
            true
          when ::RBS::Inline::AST::Annotations::Method
            annotation.method_types.is_a?(Array) && annotation.error_source.nil?
          else
            false
          end
        end
      end
    end
  end
end
