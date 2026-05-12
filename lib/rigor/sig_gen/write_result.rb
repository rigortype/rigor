# frozen_string_literal: true

module Rigor
  module SigGen
    # Per-source-file outcome of a `rigor sig-gen --write` run.
    #
    # The writer reports back what it did so the renderer (and
    # the CLI's exit-status logic) can summarise actions and
    # surface user-authored-skip decisions without having to
    # re-parse the produced files.
    #
    # - `source_path` — original `.rb` file.
    # - `target_path` — `.rbs` file the writer was responsible
    #   for (`nil` when the source path falls outside the
    #   project signature tree, in which case `action` is
    #   `:skipped_outside_sig_root`).
    # - `action` — one of `:created` / `:updated` / `:noop` /
    #   `:skipped_outside_sig_root`.
    # - `applied` — the {MethodCandidate}s that actually
    #   landed on disk.
    # - `skipped` — the {MethodCandidate}s the writer
    #   declined (e.g. tighter-return without `--overwrite`).
    #   Each entry pairs the candidate with a skip reason
    #   keyword (`:user_authored`).
    class WriteResult
      attr_reader :source_path, :target_path, :action, :applied, :skipped

      def initialize(source_path:, target_path:, action:, applied: [], skipped: [])
        @source_path = source_path
        @target_path = target_path
        @action = action
        @applied = applied.freeze
        @skipped = skipped.freeze
        freeze
      end

      def to_h
        {
          source: source_path,
          target: target_path&.to_s,
          action: action.to_s,
          applied: applied.map(&:to_h),
          skipped: skipped.map { |c, reason| c.to_h.merge(write_skip_reason: reason.to_s) }
        }
      end
    end
  end
end
