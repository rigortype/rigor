# frozen_string_literal: true

require "json"

require_relative "classification"
require_relative "superclass_spelling"

module Rigor
  module SigGen
    # Output formatter for `rigor sig-gen`.
    #
    # Supports three modes:
    # - `:print` (default) — RBS skeletons grouped by source file and class declaration, ready for the user to
    #   paste into `sig/<path>.rbs`.
    # - `:diff` — a unified-style diff comparing the existing RBS spelling (if any) against the inferred
    #   spelling. The MVP renders a minimal "- declared / + inferred" block; full per-file diffing arrives with
    #   slice 2's `--write` merge.
    # - `:json` — machine-readable payload with the same classification table as `:print`, plus every `skipped`
    #   row with its `skip_reason` (#778).
    class Renderer
      def initialize(out:)
        @out = out
      end

      # @param format — "text" or "json"
      # @param selection — subset of
      #   {Classification} constants to include; an empty
      #   array means "all emittable classifications".
      def render(candidates:, mode:, format:, selection:)
        case format
        when "json" then render_json(filter(candidates, selection, with_skipped: true))
        when "text"
          filtered = filter(candidates, selection)
          mode == :diff ? render_diff(filtered) : render_print(filtered)
        else
          raise ArgumentError, "unsupported format: #{format}"
        end
      end

      private

      # The emittable rows the selection asks for. JSON also carries every `skipped` row whatever the selection:
      # ADR-14 makes the JSON payload the surface where `sig.skipped.*` is reported, and a consumer asking why a
      # method is missing from its `sig/` needs the reason next to the rows that did emit (#778 — the rows were
      # built with their `skip_reason` and then dropped here). `equivalent` rows stay out: nothing to do,
      # nothing to explain.
      def filter(candidates, selection, with_skipped: false)
        active = selection.empty? ? Classification::EMITTABLE : selection
        candidates.select do |c|
          active.include?(c.classification) || (with_skipped && c.classification == Classification::SKIPPED)
        end
      end

      def render_print(candidates)
        if candidates.empty?
          @out.puts("No candidates")
          return
        end

        grouped = candidates.group_by(&:path)
        grouped.each do |path, items|
          @out.puts("# #{path}")
          render_classes(items)
          @out.puts
        end
      end

      def render_classes(items)
        items.group_by(&:class_name).each do |class_name, methods|
          @out.puts(declaration_header(methods.first, class_name))
          methods.each do |candidate|
            tag = case candidate.classification
                  when Classification::NEW_METHOD then "[new]"
                  when Classification::NEW_FILE then "[new-file]"
                  when Classification::TIGHTER_RETURN
                    "[tighter, was: #{candidate.declared_return_rbs}]"
                  when Classification::INLINE_UPDATE
                    "[inline-update, was: #{candidate.declared_rbs}]"
                  end
            @out.puts("  # #{tag}")
            # Annotations first: an RBS annotation binds the declaration BELOW it, so `%a{pure}` printed
            # after the `def` line would bind the next member — or nothing at all at the end of a class.
            candidate.rbs_lines.each { |line| @out.puts("  #{line}") }
          end
          @out.puts("end")
        end
      end

      # The keyword and ancestry for a printed group, from the same per-file maps the `--write` path reads. Print
      # mode used to hard-code `class`, which turned a module into a class the moment it held an emittable method —
      # output that raises `RBS::DuplicatedDeclarationError` on load if the real `module` is declared anywhere else
      # (#227). Defaulting to `class` when the map has no entry keeps the pre-existing spelling for a leaf class.
      def declaration_header(candidate, class_name)
        return "module #{class_name}" if candidate.namespace_kinds[class_name] == :module

        superclass = candidate.class_superclasses[class_name]
        superclass ? "class #{class_name} < #{SuperclassSpelling.absolute(superclass)}" : "class #{class_name}"
      end

      def render_diff(candidates)
        if candidates.empty?
          @out.puts("No candidates")
          return
        end

        candidates.each do |candidate|
          @out.puts("--- #{candidate.path}: #{candidate.class_name}##{candidate.method_name}")
          render_removed_line(candidate)
          candidate.rbs_lines.each { |line| @out.puts("+ #{line}") }
          @out.puts
        end
      end

      # An inline update replaces a whole `sig/` line, which it carries; every other row knows only the
      # declared return.
      def render_removed_line(candidate)
        if candidate.declared_rbs
          @out.puts("- #{candidate.declared_rbs}")
        elsif candidate.declared_return_rbs
          @out.puts("- def #{candidate.method_name}: () -> #{candidate.declared_return_rbs}")
        end
      end

      def render_json(candidates)
        payload = { candidates: candidates.map(&:to_h) }
        @out.puts(JSON.pretty_generate(payload))
      end

      public

      # Renders the per-source-file outcomes of a `--write` run. Distinct from {#render} because the write
      # path's reporting surface is action-oriented (created / updated / skipped) rather than candidate-oriented.
      def render_write(results:, format:)
        case format
        when "json" then render_write_json(results)
        when "text" then render_write_text(results)
        else raise ArgumentError, "unsupported format: #{format}"
        end
      end

      # ADR-112 WD4 — `sig-gen --check`: the results of a dry-run `--write`. Only the targets `--write` would
      # change (or refuse) are shown, each with the lines it would add; the verdict is the exit status, which
      # the command derives from the same results ({.out_of_date}).
      #
      # @param refused — the methods the generator refused to reconcile (`sig.skipped.inline-shape-mismatch`):
      #   `sig/` is not up to date while one stands, and `--write` cannot fix it.
      def render_check(results:, format:, refused: [])
        stale = self.class.out_of_date(results)
        case format
        when "json"
          @out.puts(JSON.pretty_generate({ up_to_date: stale.empty? && refused.empty?,
                                           results: stale.map { |r| check_entry(r) },
                                           refused: refused.map(&:to_h) }))
        when "text" then render_check_text(stale, refused)
        else raise ArgumentError, "unsupported format: #{format}"
        end
      end

      # One line per method sig-gen refused to reconcile with its `sig/` copy. Shared by `--write` (on stderr,
      # next to the write report) and `--check`.
      def self.refusal_lines(refused)
        refused.map do |candidate|
          separator = candidate.kind == :singleton ? "." : "#"
          "REFUSED #{candidate.path}: #{candidate.class_name}#{separator}#{candidate.method_name} — the inline " \
            "declaration's overloads or parameters do not correspond to its sig/ copy, so neither was changed " \
            "(#{Classification::SKIP_DIAGNOSTIC_IDS.fetch(candidate.skip_reason)}). Make the two agree by hand."
        end
      end

      # The results that make a `--check` fail: a target `--write` would create or change, and one it would
      # refuse, since a write that cannot happen is not an up-to-date `sig/` either.
      def self.out_of_date(results)
        results.reject { |result| %i[noop skipped_outside_sig_root].include?(result.action) }
      end

      # Nothing was written, so the entry must not read like one that was: `created` / `updated` become
      # `would_create` / `would_update`. A refusal keeps its action — `--write` would refuse the same way.
      CHECK_ACTIONS = { created: "would_create", updated: "would_update" }.freeze
      private_constant :CHECK_ACTIONS

      private

      def check_entry(result)
        entry = result.to_h
        entry[:action] = CHECK_ACTIONS.fetch(result.action, entry[:action])
        entry
      end

      def render_check_text(stale, refused)
        if stale.empty? && refused.empty?
          @out.puts("sig/ is up to date")
          return
        end

        self.class.refusal_lines(refused).each { |line| @out.puts(line) }

        stale.each do |result|
          case result.action
          when :created, :updated then render_check_change(result)
          when :skipped_invalid_rbs then render_write_invalid(result)
          when :skipped_invalid_encoding then render_write_invalid_encoding(result)
          end
        end
      end

      def render_check_change(result)
        counts = result.action == :created ? "#{result.applied.size} method(s)" : applied_counts(result)
        verb = result.action == :created ? "would create" : "would update"
        @out.puts("#{verb} #{result.target_path} (#{counts})")
        result.applied.each do |candidate|
          @out.puts("  - #{candidate.declared_rbs}") if candidate.declared_rbs
          candidate.rbs_lines.each { |line| @out.puts("  + #{line}") }
        end
      end

      def render_write_text(results)
        if results.all? { |r| r.action == :noop }
          @out.puts("No changes")
          return
        end

        results.each do |result|
          case result.action
          when :created then render_write_created(result)
          when :updated then render_write_updated(result)
          when :skipped_outside_sig_root then render_write_skipped(result)
          when :skipped_invalid_rbs then render_write_invalid(result)
          when :skipped_invalid_encoding then render_write_invalid_encoding(result)
          end
        end
      end

      # `+N` counts added lines; an existing line replaced (`--overwrite`, or an inline update) is counted apart,
      # because "added 2" when one of them rewrote a line the project already had would understate the change.
      def applied_counts(result)
        added = "+#{result.applied.size - result.replaced.size}"
        result.replaced.empty? ? added : "#{added}, replaced #{result.replaced.size}"
      end

      def render_write_created(result)
        @out.puts("created #{result.target_path} (#{result.applied.size} method(s))")
      end

      def render_write_updated(result)
        @out.puts("updated #{result.target_path} (#{applied_counts(result)}, " \
                  "skipped #{result.skipped.size} user-authored)")
        render_left_unreadable(result)
      end

      # ADR-103 WD9 — the declarations whose annotation region the writer refused to rewrite. Named per
      # method rather than counted: the fix is a human reading one existing annotation and deciding what
      # it should say, and there is no count of those a reader could act on.
      def render_left_unreadable(result)
        return if result.left_unreadable.empty?

        @out.puts("  left #{result.left_unreadable.size} existing annotation(s) byte-untouched " \
                  "(sig.effect.left-unreadable):")
        result.left_unreadable.each do |candidate|
          @out.puts("    #{candidate.class_name}##{candidate.method_name} — " \
                    "would have emitted #{candidate.annotations.join(' ')}")
        end
      end

      def render_write_skipped(result)
        @out.puts("skipped #{result.source_path} -> #{result.target_path} (outside sig root)")
      end

      # The assembled file does not parse, so it was NOT written. Writing it would poison the sig tree — the
      # consumer quarantines an unparseable `.rbs` whole, taking every other type in that file down with it,
      # including the user's own hand-written ones.
      def render_write_invalid(result)
        @out.puts("REFUSED #{result.target_path} — the generated RBS does not parse, so it was not written")
        @out.puts("  #{result.error}")
        @out.puts("  This is a bug in Rigor's RBS rendering, not in your code — please report it.")
      end

      # The EXISTING target file is not valid UTF-8, so the writer will not merge into it — the opposite
      # attribution from {#render_write_invalid}: this one is the file's problem, and the fix is the user's.
      def render_write_invalid_encoding(result)
        @out.puts("REFUSED #{result.target_path} — the existing file is not valid UTF-8, so it was not updated")
        @out.puts("  Re-save the file as UTF-8 and re-run; sig-gen never modifies a file it cannot read faithfully.")
      end

      def render_write_json(results)
        @out.puts(JSON.pretty_generate({ results: results.map(&:to_h) }))
      end
    end
  end
end
