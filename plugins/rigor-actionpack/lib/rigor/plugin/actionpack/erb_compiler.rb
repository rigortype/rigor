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
      # (`erubi-1.13.1` / `erb-5.0.2`), which rides the unit digest — so a project that installs Erubi
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
        PROBE = (1..3).map { |n| "<% RIGOR_ERB_PROBE_#{n} %>\n" }.join
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

        # `[ruby_source, line_map, transform_id]` for one template's bytes.
        #
        # `line_map` is `{ compiled line => template line }` for every template line, explicitly — NOT the
        # empty "identity" map, even when the offset is zero. An empty map tells the engine the transform
        # was byte-preserving and lets the compiled Ruby's COLUMNS through, and an ERB column names
        # nothing in the template (`macro-substrate.md` § Positions).
        def compile(source)
          text = source.dup.force_encoding(Encoding::UTF_8)
          text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless text.valid_encoding?
          offset = line_offset
          raise Unmappable, "#{transform_id} does not emit template lines one per compiled line" if offset.nil?

          compiled = compile_source(normalize(text))
          map = (1..template_line_count(text)).to_h { |line| [line + offset, line] }
          [compiled, map, transform_id]
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
          normalize_block_expressions(text.gsub(TRIM_OPEN, "<% ").gsub(TRIM_CLOSE, " %>"))
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

        # `erubi-1.13.1` / `erb-5.0.2` — the compiler's identity, which rides the unit digest.
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
