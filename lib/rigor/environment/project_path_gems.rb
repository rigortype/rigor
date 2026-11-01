# frozen_string_literal: true

require_relative "../analysis/path_expansion"

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
    # checkout — is a dependency and keeps its collection RBS.
    #
    # #2592 — a reached gem counts only when the file walker would analyse at least one of its Ruby files: some
    # `**/*.rb` under the part of the gem a `paths:` entry covers survives `Analysis::PathExpansion.reject_excluded`.
    # A gem whose Ruby the configuration's `exclude:` patterns all leave out — `vendor/**`, `vendor/**/*.rb`, or
    # `vendor/gems/foo/lib/**` when `lib/` holds all of it — keeps its collection RBS, and so does a reached
    # directory with no Ruby at all. Both sides are compared as real paths, so a symlinked spelling of the same
    # directory matches.
    module ProjectPathGems
      module_function

      # @param locked — `{name => LockfileResolver::LockedGem}`.
      # @param paths — the configured `paths:` entries; relative ones resolve against `root`.
      # @param exclude_patterns — the configuration's `exclude_patterns`, matched against `exclude_base`.
      # @return frozen set of gem names. Empty when `paths` is nil or empty.
      def names(locked, paths:, root: Dir.pwd, exclude_patterns: [], exclude_base: root)
        roots = Array(paths).map { |path| real(File.expand_path(path.to_s, root.to_s)) }.uniq
        return Set.new.freeze if roots.empty?

        locked.each_value.filter_map do |gem|
          dir = gem.path_source
          next unless dir

          dir = real(dir)
          covered = roots.filter_map do |path|
            if at_or_under?(dir, path) then dir
            elsif at_or_under?(path, dir) then path
            end
          end
          gem.name if analysed_ruby?(covered.uniq, exclude_patterns, exclude_base)
        end.to_set.freeze
      end

      # True when `path` is `dir` or lies under it. Joined with a `/` only when `dir` does not already end in one,
      # so `/` reaches everything without spelling `//`, and `/proj/lib2` is not under `/proj/lib`.
      def at_or_under?(path, dir)
        return true if path == dir

        path.start_with?(dir.end_with?("/") ? dir : "#{dir}/")
      end

      # Files are matched in slices, so a large gem stops at the first slice holding a surviving file.
      EXCLUDE_SLICE = 256
      private_constant :EXCLUDE_SLICE

      # True when some `.rb` file under one of `dirs` survives the `exclude:` patterns, as the file walker
      # ({Analysis::PathExpansion.directory_files}) reads them.
      def analysed_ruby?(dirs, patterns, base)
        patterns = Array(patterns)
        dirs.any? do |dir|
          files = RootedGlob.glob(dir, Analysis::PathExpansion::RUBY_GLOB)
          next !files.empty? if patterns.empty?

          files.each_slice(EXCLUDE_SLICE).any? do |slice|
            !Analysis::PathExpansion.reject_excluded(slice, patterns, base: base.to_s).empty?
          end
        end
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
    end
  end
end
