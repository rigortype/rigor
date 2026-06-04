# frozen_string_literal: true

module Rigor
  module Analysis
    # ADR-46 slice 2 — the pure set-algebra core of the incremental step,
    # kept side-effect-free and Runner-independent so the soundness
    # property it encodes is unit-testable without the analysis machinery.
    #
    # Given the files that changed since the baseline run and the
    # baseline's `dependents` index ({Runner#file_dependents}), the
    # **affected closure** the body tier must re-analyse is the changed set
    # plus every file that read a declaration or method body from a changed
    # file. Every other file is served from the per-file diagnostic cache.
    #
    # The soundness invariant (the {Runner}-driven `--verify-incremental`
    # gate and the spec assert it): for an edit whose declaration-structure
    # fingerprint is unchanged (a method-body edit — no symbol created,
    # destroyed, moved, or re-parented), the set of files whose diagnostics
    # actually change is a SUBSET of {affected}. A file outside the closure
    # whose diagnostics changed would be served stale — a manufactured
    # false positive/negative, the failure mode this design exists to
    # prevent. Structural edits (fingerprint changed) are out of this
    # tier's scope — they widen via the negative-dependency / full fallback
    # path (slice 3).
    module Incremental
      module_function

      # The closure the body tier re-analyses. `changed` is any Enumerable
      # of paths; `dependents` maps a source path to the Set of files that
      # read from it (missing key → no dependents). Returns a frozen Set.
      def affected(changed, dependents)
        closure = changed.to_set
        changed.each { |file| closure.merge(dependents[file] || []) }
        closure.freeze
      end

      # The files whose per-file diagnostics differ between two runs.
      # Each argument maps a path to its diagnostic list; diagnostics are
      # compared structurally via {Diagnostic#to_h} so identity / ordering
      # of the objects themselves does not matter. A file present in one
      # run and absent (zero diagnostics) in the other counts as changed.
      def changed_files(before_by_file, after_by_file)
        (before_by_file.keys | after_by_file.keys).each_with_object(Set.new) do |path, changed|
          before = (before_by_file[path] || []).map(&:to_h)
          after = (after_by_file[path] || []).map(&:to_h)
          changed << path unless before == after
        end.freeze
      end
    end
  end
end
