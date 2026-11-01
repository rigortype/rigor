# frozen_string_literal: true

module Rigor
  class Environment
    # Issue #2441 — the locked gems that ARE the analysed project: a `PATH` stanza whose directory Rigor analyses
    # as project source. `rbs collection install` still fetches community RBS for such a gem (its generator skips
    # only a `gemspec` source), and the project's `sig/` declares the same classes, so the collection copy would
    # double-declare every member. The same gem is not `:missing` RBS either, so it must not make an ADR-72
    # overlay or a WD9 missing-gem index entry eligible.
    #
    # "Analysed as project source" means the gem's directory is at or under one of the configured `paths:`
    # entries, or contains one: rails lists `actionpack/lib` in `paths:` and locks `actionpack` from
    # `PATH remote: actionpack`. A `PATH` gem no `paths:` entry reaches — a vendored `vendor/gems/foo`, a sibling
    # checkout — is a dependency and keeps its collection RBS. Both sides are compared as real paths, so a
    # symlinked spelling of the same directory matches.
    module ProjectPathGems
      module_function

      # @param locked — `{name => LockfileResolver::LockedGem}`.
      # @param paths — the configured `paths:` entries; relative ones resolve against `root`.
      # @return frozen set of gem names. Empty when `paths` is nil or empty.
      def names(locked, paths:, root: Dir.pwd)
        roots = Array(paths).map { |path| real(File.expand_path(path.to_s, root.to_s)) }.uniq
        return Set.new.freeze if roots.empty?

        locked.each_value.filter_map do |gem|
          dir = gem.path_source
          next unless dir

          dir = real(dir)
          gem.name if roots.any? { |path| at_or_under?(path, dir) || at_or_under?(dir, path) }
        end.to_set.freeze
      end

      # True when `path` is `dir` or lies under it. Joined with a `/` only when `dir` does not already end in one,
      # so `/` reaches everything without spelling `//`, and `/proj/lib2` is not under `/proj/lib`.
      def at_or_under?(path, dir)
        return true if path == dir

        path.start_with?(dir.end_with?("/") ? dir : "#{dir}/")
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
    end
  end
end
