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
    #   `:skipped_invalid_rbs`.
    # - `applied` — the {MethodCandidate}s that actually landed on disk.
    # - `skipped` — the {MethodCandidate}s the writer declined (e.g. tighter-return without `--overwrite`). Each
    #   entry pairs the candidate with a skip reason keyword (`:user_authored`).
    # - `error` — the parse error, when `action` is `:skipped_invalid_rbs`: the file the writer assembled does
    #   not parse, so it was NOT written (writing it would poison the project's sig tree — the consumer
    #   quarantines an unparseable `.rbs`, taking every other type in that file down with it).
    class WriteResult
      attr_reader :source_path, :target_path, :action, :applied, :skipped, :error

      def initialize(source_path:, target_path:, action:, applied: [], skipped: [], error: nil)
        @source_path = source_path
        @target_path = target_path
        @action = action
        @applied = applied.freeze
        @skipped = skipped.freeze
        @error = error
        freeze
      end

      def to_h
        {
          source: source_path,
          target: target_path&.to_s,
          action: action.to_s,
          applied: applied.map(&:to_h),
          skipped: skipped.map { |c, reason| c.to_h.merge(write_skip_reason: reason.to_s) }
        }.tap { |h| h[:error] = error if error }
      end
    end
  end
end
