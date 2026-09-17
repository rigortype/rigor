# frozen_string_literal: true

require "erb"

require "rigor/plugin"
require "rigor/plugin/isolation"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # #393 — ERB → Ruby, with the line map the template-unit seam (#392) reports through.
      #
      # ## Which compiler
      #
      # [ADR-90](../../../../../../docs/adr/90-target-library-resolution-from-project-bundle.md): Erubi is
      # **never bundled** — it is not a Rigor dependency and nothing here adds it to a Gemfile — but it is
      # what Rails itself compiles with, so it is used when it resolves in the ANALYSED project's bundle,
      # through the same `Isolation.require_with_target_bundle` path `Inflector` takes. Stdlib `ERB` is the
      # fallback, and it is always there. Whichever ran is reported as the unit's `transform_id`
      # (`erubi-1.13.1` / `erb-6.0.1.1`), which rides the unit digest — so a project that installs Erubi
      # between two runs re-analyses rather than replaying the stdlib answer.
      #
      # ## The line map is measured, never assumed
      #
      # Both compilers are line-preserving: a tag's text is rewritten in place and the newlines between
      # tags are emitted verbatim, which is why a Rails backtrace can name `show.html.erb:12`. What differs
      # is the **prologue** — stdlib ERB emits a `#coding:` magic comment above the body, Erubi emits its
      # buffer initialiser — and neither documents its height as API.
      #
      # So the height is measured rather than hardcoded: {.line_offset} compiles a probe template of marked
      # lines once per compiler and reads back which compiled line the first marker landed on, checking at
      # the same time that the following markers step by exactly one. A compiler that fails that check is
      # refused (the caller declines the file) rather than trusted, because the failure mode of a wrong
      # offset is every finding in every template reported at the wrong line — silent, and worse than no
      # unit at all.
      module ErbCompiler
        # A compiler whose probe did not step line-for-line. Caught by {Actionpack#template_units_for_file},
        # which declines the file.
        class Unmappable < StandardError; end

        # Three marked lines, each a STATEMENT tag. A tag's Ruby is emitted verbatim, so the marker is
        # findable in the compiled source and each one is forced onto its own compiled line.
        #
        # Plain text would not do: consecutive text lines are one chunk and are emitted as ONE append
        # carrying the newlines escaped inside the literal — the compiler then pads the missing lines out
        # BELOW it, so a text probe reads as a collapse when the line numbering is in fact intact. That
        # padding is exactly the property being measured, and a tag probe measures it without tripping
        # over how the padding is spelled.
        PROBE = (1..3).map { |n| "<% RIGOR_ERB_PROBE_#{n} %>\n" }.join.freeze
        private_constant :PROBE

        # An output tag whose Ruby OPENS A BLOCK: `<%= form_with(model: @user) do |f| %>`, the single most
        # common shape in a real Rails view. Neither compiler handles it — both emit
        # `_buf << (form_with(…) do |f|).to_s`, which is a syntax error, so every template using a form
        # helper produced two parse diagnostics and no unit at all (431 of them on redmine, measured).
        #
        # Rails does not hit this because its own ERB handler carries exactly this rule
        # (`ActionView::Template::Handlers::ERB::BLOCK_EXPR`) and emits `@output_buffer.append= expr`
        # unwrapped for a matching tag. The same rule is applied here one step earlier, as a rewrite of
        # the TEMPLATE rather than of a compiler's output: `<%=` becomes `<%` for such a tag, which is a
        # same-width, same-line edit both compilers then handle, and the discarded value is the buffer
        # append the design note says is not an origin anyway.
        BLOCK_EXPR = /\s*((\s+|\))do|\{)(\s*\|[^|]*\|)?\s*\z/
        private_constant :BLOCK_EXPR

        # The Erubi/Rails trim markers, which stdlib ERB only understands under a `trim_mode:` that also
        # changes how it emits newlines. They are blanked instead — `<%-` → `<% `, `-%>` → ` %>` — which
        # is the same-width, same-line rewrite {BLOCK_EXPR} uses and keeps the line map out of the
        # compiler's trim rules entirely. Left in place under `trim_mode: nil` they parse as Ruby's unary
        # minus and cost the template its unit (87 of redmine's 506, measured after the block-expression
        # fix and before this one).
        TRIM_OPEN = /<%-/
        private_constant :TRIM_OPEN

        TRIM_CLOSE = /-%>/
        private_constant :TRIM_CLOSE

        # #1047 — a LAYOUT's `yield`. `<%= yield %>`, `<%= yield :sidebar %>` and `<% if content_for?(:x) %>`
        # are what a layout is made of, and the first two are legal ERB and illegal Ruby anywhere outside a
        # method body — so every layout's compiled source failed to parse and the file was declined (four of
        # redmine's 506 templates, two of mastodon's 46; `docs/notes/20260917-erb-template-units.md` § 3).
        #
        # The seam deliberately does NOT wrap a unit's body in a synthesised method
        # (`docs/internal-spec/macro-substrate.md` § Positions: wrapping would shift every line and compose
        # a second line map onto the plugin's), so the fix is a rewrite of the TEMPLATE, in the same pre-pass
        # {BLOCK_EXPR} and {TRIM_OPEN} live in: the `yield` KEYWORD inside an ERB tag becomes a call to
        # {YIELD_METHOD}, an ordinary implicit-self method on the synthesised view context, declared in
        # `sig/action_view.rbs` as returning `String`.
        #
        # Unlike the other two rewrites this one is NOT width-preserving, and it does not have to be: a unit
        # whose `line_map` is non-empty reports at column 1 by construction
        # ({Analysis::TemplateUnits#remap} — "the template's lines and the compiled Ruby's columns do not
        # correspond"), so only the LINE count is load-bearing, and the replacement contains no newline.
        #
        # What the rewrite deliberately does not do is give the call a TYPE beyond `String`. Rails' `yield`
        # returns whatever the inner template's buffer holds, and `yield :sidebar` returns the `content_for`
        # buffer — an empty `SafeBuffer` when nothing was provided, never nil. A lenient `String` is the
        # widest honest reading, and inventing anything narrower would be the `Parameters#[]` trap one
        # layer up.
        YIELD_METHOD = "__rigor_yield"

        # The `yield` keyword, and only the keyword: not `foo.yield`, not `:yield`, not `@yield`, not
        # `yielding`. A `yield` inside a STRING literal in a tag (`<%= t("yield") %>`) is rewritten too —
        # the pre-pass is a Regexp over the tag, not a Ruby lexer — which changes a literal's bytes in a
        # body that is never executed and that no rule reads the contents of. Recorded rather than guarded,
        # because a lexer here would be a second Ruby parser to keep honest.
        YIELD_KEYWORD = /(?<![A-Za-z0-9_.:@$])yield(?![A-Za-z0-9_?!])/
        private_constant :YIELD_KEYWORD

        # Any ERB tag, non-greedy and multi-line — the region {YIELD_KEYWORD} is applied inside, so a
        # `yield` in the template's HTML text is left exactly as it was written. A `<%%` opener is ERB's
        # escape for a LITERAL `<%` in the output, so what follows it is text too and is skipped.
        ANY_TAG = /<%.*?%>/m
        private_constant :ANY_TAG

        # `<%= … %>` and `<%== … %>`, non-greedy and multi-line. No capture group: the block below reads
        # the tag it was handed rather than `Regexp.last_match`, whose group is `String?` however sure
        # the pattern makes it — and a rewrite that depends on global match state is the harder one to
        # read anyway.
        OUTPUT_TAG = /<%={1,2}(?!=).*?%>/m
        private_constant :OUTPUT_TAG

        # The `<%=` / `<%==` opener of a matched tag, which is all that gets rewritten.
        OUTPUT_OPENER = /\A<%=+/
        private_constant :OUTPUT_OPENER

        module_function

        # `[ruby_source, line_map, transform_id]` for one template's bytes. `text` must already be valid
        # UTF-8 — {.scrub} is the caller's, because more than one thing reads the template and every one
        # of them has to read the SAME bytes.
        #
        # `line_map` is `{ compiled line => template line }` for every template line, explicitly — NOT the
        # empty "identity" map, even when the offset is zero. An empty map tells the engine the transform
        # was byte-preserving and lets the compiled Ruby's COLUMNS through, and an ERB column names
        # nothing in the template (`macro-substrate.md` § Positions).
        def compile(text)
          offset = line_offset
          raise Unmappable, "#{transform_id} does not emit template lines one per compiled line" if offset.nil?

          compiled = compile_source(normalize(text))
          map = (1..template_line_count(text)).to_h { |line| [line + offset, line] }
          [compiled, map, transform_id]
        end

        # A template's bytes as valid UTF-8. A `.erb` file is whatever the project committed, and an
        # invalid byte is not a reason to refuse it: `ERB`, `Regexp#match?` and Prism all raise on one,
        # so every reader has to be handed the same scrubbed String or they disagree about the file.
        def scrub(source)
          text = source.to_s.dup.force_encoding(Encoding::UTF_8)
          return text if text.valid_encoding?

          text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end

        # The compiled Ruby for one template, through whichever compiler resolved.
        def compile_source(text)
          if erubi?
            ::Erubi::Engine.new(text).src
          else
            ::ERB.new(text, trim_mode: nil).src
          end
        end

        # Rewrites every block-opening output tag into a statement tag; see {BLOCK_EXPR}. Line- and
        # width-preserving by construction: only the tag's `=` characters are replaced, by spaces.
        def normalize(text)
          normalize_block_expressions(normalize_yields(text.gsub(TRIM_OPEN, "<% ").gsub(TRIM_CLOSE, " %>")))
        end

        # Rewrites the `yield` keyword inside every ERB tag into a call on the view context; see
        # {YIELD_METHOD}. Runs BEFORE {#normalize_block_expressions} so that pass reads the tag bodies it
        # will actually hand to the compiler.
        def normalize_yields(text)
          return text unless text.match?(YIELD_KEYWORD)

          text.gsub(ANY_TAG) { |tag| tag.start_with?("<%%") ? tag : tag.gsub(YIELD_KEYWORD, YIELD_METHOD) }
        end

        def normalize_block_expressions(text)
          text.gsub(OUTPUT_TAG) do |tag|
            opener = tag[OUTPUT_OPENER]
            next tag if opener.nil?

            body = tag[opener.length...-2].to_s
            next tag unless body.match?(BLOCK_EXPR)

            "<%#{' ' * (opener.length - 2)}#{body}%>"
          end
        end

        # A template's last line may lack its newline; `String#lines` already counts it, and an EMPTY
        # template has no lines at all and needs no rows.
        def template_line_count(text)
          text.lines.length
        end

        # How many compiled lines sit above the template's first line. Measured once per process per
        # compiler — the answer cannot change under a loaded compiler, and the probe compile is cheap
        # enough that memoising it is about tidiness rather than cost.
        def line_offset
          return @line_offset if defined?(@line_offset) && @line_offset

          @line_offset = probe_offset
        end

        # `nil` when the loaded compiler does not step line-for-line.
        def probe_offset
          lines = compile_source(PROBE).lines
          first = lines.index { |line| line.include?("RIGOR_ERB_PROBE_1") }
          return nil if first.nil?

          (2..3).each do |marker|
            return nil unless lines[first + marker - 1]&.include?("RIGOR_ERB_PROBE_#{marker}")
          end
          first
        end

        # `erubi-1.13.1` / `erb-6.0.1.1` — the compiler's identity, which rides the unit digest.
        def transform_id
          @transform_id ||= if erubi?
                              "erubi-#{::Erubi::VERSION}"
                            else
                              "erb-#{::ERB.const_defined?(:VERSION) ? ::ERB::VERSION : 'stdlib'}"
                            end
        end

        # True once Erubi has been loaded out of the analysed project's bundle AND its line numbering has
        # been measured. Resolved ONCE per process: a failed resolution is as memoised as a successful
        # one, so a project without Erubi does not pay a `$LOAD_PATH` walk per template.
        #
        # `Isolation.require_with_target_bundle` is [ADR-90](../../../../../../docs/adr/90-target-library-resolution-from-project-bundle.md)'s
        # path — Rigor's own gem env first, then the analysed project's bundle, `$LOAD_PATH` appended and
        # only on a failed require. Erubi is not a Rigor dependency and is never added to one. Any load
        # failure is equally "no Erubi here"; stdlib `ERB` answers the same question, so nothing is
        # reported and nothing degrades but the compiler's name.
        #
        # A resolved Erubi that does NOT step line-for-line is **demoted** rather than trusted. Erubi pads
        # its output to the template's line count deliberately (it is why a Rails backtrace can name
        # `show.html.erb:12`), so the demotion is not expected to fire — but a compiler whose numbering
        # the probe cannot confirm would silently report every finding in every template at the wrong
        # line, and stdlib ERB is right here and always present.
        def erubi?
          return @erubi if defined?(@erubi)

          @erubi = load_erubi
          return @erubi unless @erubi
          return true unless probe_offset.nil?

          @erubi = false
        end

        def load_erubi
          Isolation.require_with_target_bundle("erubi", Isolation.target_bundle_root)
          defined?(::Erubi::Engine) ? true : false
        rescue ::StandardError, ::LoadError
          false
        end

        # Test seam: forget the probed offset, the resolved compiler and its id, so one process can measure
        # both compilers. Never called by the plugin itself.
        def reset!
          remove_instance_variable(:@line_offset) if defined?(@line_offset)
          remove_instance_variable(:@transform_id) if defined?(@transform_id)
          remove_instance_variable(:@erubi) if defined?(@erubi)
        end
      end
    end
  end
end
