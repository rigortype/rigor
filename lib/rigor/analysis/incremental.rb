# frozen_string_literal: true

module Rigor
  module Analysis
    # ADR-46 slice 2 — the pure set-algebra core of the incremental step, kept side-effect-free and
    # Runner-independent so the soundness property it encodes is unit-testable without the analysis machinery.
    #
    # Given the files that changed since the baseline run and the baseline's `dependents` index
    # ({Runner#file_dependents}), the **affected closure** the body tier must re-analyse is the changed set
    # plus every file that read a declaration or method body from a changed file. Every other file is served
    # from the per-file diagnostic cache.
    #
    # The soundness invariant (the {Runner}-driven `--verify-incremental` gate and the spec assert it): for an
    # edit whose declaration-structure fingerprint is unchanged (a method-body edit — no symbol created,
    # destroyed, moved, or re-parented), the set of files whose diagnostics actually change is a SUBSET of
    # {affected}. A file outside the closure whose diagnostics changed would be served stale — a manufactured
    # false positive/negative, the failure mode this design exists to prevent. Structural edits (fingerprint
    # changed) are out of this tier's scope — they widen via the negative-dependency / full fallback path
    # (slice 3).
    module Incremental
      module_function

      # Inverts a per-consumer source map (`consumer → enumerable of source files it read from`) into the
      # `dependents` index (`source → Set of consumers that read from it`). The reverse edge the incremental
      # step walks. Returns a frozen hash of frozen Sets; a missing key reads as nil (the default proc is
      # dropped before freezing).
      def invert(sources_by_consumer)
        index = Hash.new { |hash, key| hash[key] = Set.new }
        sources_by_consumer.each do |consumer, sources|
          sources.each { |source| index[source] << consumer }
        end
        index.default_proc = nil
        index.each_value(&:freeze)
        index.freeze
      end

      # The closure the body tier re-analyses. `changed` is any Enumerable of paths; `dependents` maps a
      # source path to the Set of files that read from it (missing key → no dependents). Returns a frozen Set.
      def affected(changed, dependents)
        closure = changed.to_set
        changed.each { |file| closure.merge(dependents[file] || []) }
        closure.freeze
      end

      # ADR-46 slice 4 — inverts a per-consumer symbol-sources map (`consumer → { source_path →
      # Set<"ClassName#method"> }`) into the symbol-level dependents index: `[source_path, symbol] →
      # Set<consumer>`. Used by {affected_with_symbols} to limit fan-out to callers of symbols that actually
      # changed rather than all callers of the file.
      def invert_symbols(symbol_sources_by_consumer)
        index = Hash.new { |h, k| h[k] = Set.new }
        symbol_sources_by_consumer.each do |consumer, sources_by_file|
          sources_by_file.each do |source, symbols|
            symbols.each { |sym| index[[source, sym]] << consumer }
          end
        end
        index.default_proc = nil
        index.each_value(&:freeze)
        index.freeze
      end

      # ADR-46 slice 4 — given a set of changed file paths and two per-file symbol fingerprint maps (before
      # and after), returns the frozen Set of `[path, symbol]` pairs whose fingerprints differ (added,
      # removed, or body-changed).
      def changed_symbol_pairs(changed_files, fingerprints_before, fingerprints_after)
        pairs = Set.new
        changed_files.each do |path|
          before = fingerprints_before[path] || {}
          after  = fingerprints_after[path]  || {}
          (before.keys | after.keys).each do |sym|
            pairs << [path, sym] if before[sym] != after[sym]
          end
        end
        pairs.freeze
      end

      # ADR-46 slice 4 — the symbol-granularity affected closure.
      #
      # A consumer is included when:
      # (a) it is itself a changed file,
      # (b) it has an ancestry dep on a changed file (always re-checked — file-level), or
      # (c) it has a symbol dep on a `[file, symbol]` pair that changed.
      #
      # Consumers that only have symbol deps on a changed file, and none of their tracked symbols changed,
      # are NOT included — the slice 4 precision win.
      def affected_with_symbols(changed_files, changed_pairs, symbol_dependents, ancestry_dependents)
        closure = changed_files.to_set
        changed_files.each { |file| closure.merge(ancestry_dependents[file] || []) }
        changed_pairs.each { |pair| closure.merge(symbol_dependents[pair] || []) }
        closure.freeze
      end

      # ADR-46 slice 3 — the symbol keys (`"ClassName#method"`) that are present in a changed file's
      # after-fingerprints but were absent from its before-fingerprints: a symbol that *appeared* in this
      # edit. A symbol that merely moved between files still appears here for the destination file, but its
      # negative-dependents set is empty (nobody missed a name that already resolved elsewhere), so the
      # over-report costs nothing. Returns a frozen Set of symbol-key Strings.
      def appeared_symbols(changed_files, fingerprints_before, fingerprints_after)
        appeared = Set.new
        changed_files.each do |path|
          before = fingerprints_before[path] || {}
          after  = fingerprints_after[path]  || {}
          (after.keys - before.keys).each { |sym| appeared << sym }
        end
        appeared.freeze
      end

      # ADR-46 slice 3 — the qualified class/module names *declared* in a changed file's after-state that
      # were absent from its before-state: a class that appeared in this edit. (For an added file the
      # before-set is empty, so every class it declares appears.) A class that merely moved files still
      # appears here, but its negative-dependents are empty, so the over-report costs nothing. Returns a
      # frozen Set of qualified class-name Strings. `decls_before` / `decls_after` map a path to its Set of
      # declared class names.
      def appeared_classes(changed_files, decls_before, decls_after)
        appeared = Set.new
        changed_files.each do |path|
          before = decls_before[path] || Set.new
          after  = decls_after[path]  || Set.new
          appeared.merge(after - before)
        end
        appeared.freeze
      end

      # Issue #644 — the qualified constant names *assigned* in a changed file's after-state that were absent
      # from its before-state: a value constant that appeared in this edit. The value-constant twin of
      # {appeared_classes} (a `FOO = :sym` declares no class and so appears in no class-source table), feeding
      # the `constant:` negative kind. For an added file the before-set is empty, so every constant it
      # assigns appears. A constant that merely moved files still appears here, but its negative-dependents
      # are empty, so the over-report costs nothing. `decls_before` / `decls_after` map a path to its Set of
      # assigned constant names. Returns a frozen Set of qualified-name Strings.
      def appeared_constants(changed_files, decls_before, decls_after)
        appeared = Set.new
        changed_files.each do |path|
          before = decls_before[path] || Set.new
          after  = decls_after[path]  || Set.new
          appeared.merge(after - before)
        end
        appeared.freeze
      end

      # ADR-46 slice 3 — the consumers to re-check because a name they looked up and *missed* (a negative
      # dependency) now resolves. `keys` is the set of negative-dependency keys (`"toplevel:foo"` /
      # `"method:C#m"`) the appeared symbols would satisfy; `negative_dependents` maps each key to the Set of
      # consumers that recorded the miss. Returns a frozen Set of consumer paths.
      def negative_closure(keys, negative_dependents)
        closure = Set.new
        keys.each { |key| closure.merge(negative_dependents[key] || []) }
        closure.freeze
      end

      # The files whose per-file diagnostics differ between two runs. Each argument maps a path to its
      # diagnostic list; diagnostics are compared structurally via {Diagnostic#to_h} so identity / ordering
      # of the objects themselves does not matter. A file present in one run and absent (zero diagnostics) in
      # the other counts as changed.
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
