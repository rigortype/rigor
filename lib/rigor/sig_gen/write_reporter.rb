# frozen_string_literal: true

require "json"

require_relative "classification"

module Rigor
  module SigGen
    # Reports a `rigor sig-gen --write` run (the per-target {WriteResult}s) and the `--check` verdict. Split out of
    # {Renderer}, which formats candidates; this formats what the writer did with them.
    class WriteReporter
      def initialize(out:)
        @out = out
      end

      # Renders the per-source-file outcomes of a `--write` run. Distinct from {Renderer#render} because the write
      # path's reporting surface is action-oriented (created / updated / skipped) rather than candidate-oriented.
      # @param refused — methods refused as `sig.skipped.inline-differs`; the JSON payload names them under
      #   `refused` (absent when there are none, so an ordinary payload is unchanged), and text mode leaves them
      #   to the command's stderr `REFUSED` lines.
      def render_write(results:, format:, refused: [])
        case format
        when "json" then render_write_json(results, refused)
        when "text" then render_write_text(results)
        else raise ArgumentError, "unsupported format: #{format}"
        end
      end

      # ADR-112 WD4 — `sig-gen --check`: the results of a dry-run `--write`. Only the targets `--write` would
      # change (or refuse) are shown, each with the lines it would add; the verdict is the exit status, which
      # the command derives from the same results ({.out_of_date}).
      #
      # @param refused — the methods the generator refused to reconcile (`sig.skipped.inline-differs`):
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
          "REFUSED #{candidate.path}: #{candidate.class_name}#{separator}#{candidate.method_name} — its inline " \
            "declaration and its sig/ declaration disagree, so neither was changed " \
            "(#{Classification::SKIP_DIAGNOSTIC_IDS.fetch(candidate.skip_reason)}). Make them agree, or pass " \
            "--overwrite to replace the sig/ member with the inline declaration; `rigor explain " \
            "#{Classification::SKIP_DIAGNOSTIC_IDS.fetch(candidate.skip_reason)}` says when that is not enough."
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
        if results.all? { |r| r.action == :noop && r.skipped.empty? }
          @out.puts("No changes")
          return
        end

        results.each do |result|
          case result.action
          when :created then render_write_created(result)
          when :updated then render_write_updated(result)
          when :noop then render_write_unchanged(result)
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
        render_write_skips(result)
        render_left_unreadable(result)
      end

      # A target the writer opened and changed nothing in, because every proposal for it was a member the
      # project already declares (#1975). Without this line the run read as "No changes" or said nothing about it.
      def render_write_unchanged(result)
        return if result.skipped.empty?

        @out.puts("unchanged #{result.target_path} (skipped #{result.skipped.size} user-authored)")
        render_write_skips(result)
      end

      # One line per proposal the writer declined, so a change `--diff` or `--print` showed is never dropped
      # without a reason. The same entries are the `skipped` rows of the `--format=json` payload.
      def render_write_skips(result)
        result.skipped.each do |candidate, reason|
          separator = candidate.kind == :singleton ? "." : "#"
          label = "#{candidate.class_name}#{separator}#{candidate.method_name}"
          @out.puts("  skipped #{label} (#{reason.to_s.tr('_', '-')}): #{candidate.rbs_lines.join(' ')}")
        end
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
        render_write_skips(result)
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

      def render_write_json(results, refused)
        payload = { results: results.map(&:to_h) }
        payload[:refused] = refused.map(&:to_h) unless refused.empty?
        @out.puts(JSON.pretty_generate(payload))
      end
    end
  end
end
