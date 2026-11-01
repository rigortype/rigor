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
    # directory with no Ruby at all. A `paths:` entry naming one `.rb` file inside the gem counts that file. The
    # overlap is found on real paths, so a symlinked spelling of the same directory matches, but the files are
    # walked and matched against `exclude:` through the `paths:` entry as written, as the walker matches them.
    module ProjectPathGems
      module_function

      # @param locked — `{name => LockfileResolver::LockedGem}`.
      # @param paths — the configured `paths:` entries; relative ones resolve against `root`.
      # @param exclude_patterns — the configuration's `exclude_patterns`, matched against `exclude_base`.
      # @return frozen set of gem names. Empty when `paths` is nil or empty.
      def names(locked, paths:, root: Dir.pwd, exclude_patterns: [], exclude_base: root)
        entries = Array(paths).map do |path|
          logical = File.expand_path(path.to_s, root.to_s)
          [logical, real(logical)]
        end.uniq
        return Set.new.freeze if entries.empty?

        locked.each_value.filter_map do |gem|
          dir = gem.path_source
          next unless dir

          dir = real(dir)
          covered = entries.filter_map { |logical, real_entry| covered_part(dir, logical, real_entry) }
          gem.name if covered.uniq.any? { |part| analysed_ruby?(part, Array(exclude_patterns), exclude_base.to_s) }
        end.to_set.freeze
      end

      # The part of the gem at real directory `dir` that the `paths:` entry covers, spelled through the entry as
      # written (`logical`), as the file walker spells the files it matches `exclude:` against: the entry itself
      # when it lies at or under the gem, or the gem's directory reached through the entry when the gem lies under
      # it. Nil when they do not overlap.
      def covered_part(dir, logical, real_entry)
        return logical if at_or_under?(real_entry, dir)
        return unless at_or_under?(dir, real_entry)

        rest = dir.byteslice(real_entry.bytesize..).delete_prefix("/")
        rest.empty? ? logical : File.join(logical, rest)
      end

      # True when `path` is `dir` or lies under it. Joined with a `/` only when `dir` does not already end in one,
      # so `/` reaches everything without spelling `//`, and `/proj/lib2` is not under `/proj/lib`.
      def at_or_under?(path, dir)
        return true if path == dir

        path.start_with?(dir.end_with?("/") ? dir : "#{dir}/")
      end

      # Files are matched in slices as the walk finds them, so a large gem stops at the first slice holding a
      # surviving file instead of listing its whole tree first (`Dir.glob` with a block still builds the list).
      EXCLUDE_SLICE = 64
      private_constant :EXCLUDE_SLICE

      # True when the file walker ({Analysis::PathExpansion.ruby_files}) would analyse some `.rb` file of `part`:
      # the `.rb` file itself when `part` names one, else a `**/*.rb` under the directory, that survives `patterns`.
      def analysed_ruby?(part, patterns, base)
        return surviving?([part], patterns, base) if File.file?(part)
        return false unless File.directory?(part)

        slice = []
        found = each_ruby_file(part) do |file|
          slice << file
          next false if slice.size < EXCLUDE_SLICE

          hit = surviving?(slice, patterns, base)
          slice = []
          hit
        end
        found || surviving?(slice, patterns, base)
      end

      # Walks `dir` as `Dir.glob("dir/**/*.rb")` matches: sorted, no dot-named entries, no descent through a
      # symlinked directory. Stops and returns true as soon as the block returns true.
      def each_ruby_file(dir, &)
        Dir.children(dir).sort.each do |name|
          next if name.start_with?(".")

          path = File.join(dir, name)
          if name.end_with?(".rb") && !File.directory?(path)
            return true if File.exist?(path) && yield(path)
          elsif File.directory?(path) && !File.symlink?(path)
            return true if each_ruby_file(path, &)
          end
        end
        false
      rescue SystemCallError
        false
      end

      def surviving?(files, patterns, base)
        return false if files.empty?
        return files.any? { |file| file.end_with?(".rb") } if patterns.empty?

        Analysis::PathExpansion.reject_excluded(files, patterns, base: base).any? { |file| file.end_with?(".rb") }
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
    end
  end
end
