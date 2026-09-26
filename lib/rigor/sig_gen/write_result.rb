# frozen_string_literal: true

module Rigor
  module SigGen
    # Per-source-file outcome of a `rigor sig-gen --write` run.
    #
    # The writer reports back what it did so the renderer (and the CLI's exit-status logic) can summarise
    # actions and surface user-authored-skip decisions without having to re-parse the produced files.
    #
    # - `source_path` — original `.rb` file.
    # - `target_path` — `.rbs` file the writer was responsible for (`nil` when the source path falls outside
    #   the project signature tree, in which case `action` is `:skipped_outside_sig_root`).
    # - `action` — one of `:created` / `:updated` / `:noop` / `:skipped_outside_sig_root` /
    #   `:skipped_invalid_rbs` / `:skipped_invalid_encoding`.
    # - `applied` — the {MethodCandidate}s that actually landed on disk.
    # - `replaced` — the subset of `applied` that replaced an existing declaration rather than adding one
    #   (`--overwrite`'s tighter returns, and inline updates).
    # - `skipped` — the {MethodCandidate}s the writer declined (e.g. tighter-return without `--overwrite`). Each
    #   entry pairs the candidate with a skip reason keyword (`:user_authored`).
    # - `left_unreadable` — the {MethodCandidate}s whose effect annotation was NOT written because the
    #   target declaration already carries annotations, so its bytes were left alone
    #   (`sig.effect.left-unreadable`; see {Writer#splice_annotations}). The signature line itself was
    #   still updated.
    # - `error` — the refusal cause, when `action` is a refusal: for `:skipped_invalid_rbs` the file the writer
    #   assembled does not parse, so it was NOT written (writing it would poison the project's sig tree — the
    #   consumer quarantines an unparseable `.rbs`, taking every other type in that file down with it); for
    #   `:skipped_invalid_encoding` the EXISTING target file is not valid UTF-8, so the writer refuses to merge
    #   into content it cannot read faithfully.
    class WriteResult
      attr_reader :source_path, :target_path, :action, :applied, :skipped, :error, :left_unreadable, :replaced

      def initialize(source_path:, target_path:, action:, applied: [], skipped: [], error: nil, # rubocop:disable Metrics/ParameterLists
                     left_unreadable: [], replaced: [])
        @source_path = source_path
        @target_path = target_path
        @action = action
        @applied = applied.freeze
        @skipped = skipped.freeze
        @error = error
        @left_unreadable = left_unreadable.freeze
        @replaced = replaced.freeze
        freeze
      end

      def to_h
        {
          source: source_path,
          target: target_path&.to_s,
          action: action.to_s,
          applied: applied.map(&:to_h),
          skipped: skipped.map { |c, reason| c.to_h.merge(write_skip_reason: reason.to_s) }
        }.tap do |h|
          h[:error] = error if error
          # Absent when nothing was replaced, so a run that only adds lines keeps its pre-#1076 payload.
          h[:replaced] = replaced.map(&:to_h) unless replaced.empty?
          # Absent rather than empty when nothing was left: an effects-off payload stays byte-identical
          # to a pre-#391 one.
          h[:effect_left_unreadable] = left_unreadable.map(&:to_h) unless left_unreadable.empty?
        end
      end
    end
  end
end
