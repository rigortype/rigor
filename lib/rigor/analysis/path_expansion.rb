# frozen_string_literal: true

module Rigor
  module Analysis
    # ADR-87 WD4 — project file-set expansion shared by the {Analysis::Runner} (miss path) and the
    # boot-slimming {RunCacheProbe}, so both resolve the IDENTICAL analyzed-path SET that feeds the run cache
    # key's `paths` slot. A directory argument globs `**/*.rb` and drops excluded paths; a `.rb` file argument
    # is taken verbatim; anything else contributes no files here (the Runner layers its own path-error
    # diagnostics and buffer / in-memory handling on top — none of which add or remove files for an ordinary
    # on-disk check, so the two file sets agree).
    module PathExpansion
      RUBY_GLOB = "**/*.rb"

      module_function

      # The `.rb` files an ordinary (non-buffer) check over `paths` would analyze.
      def ruby_files(paths, exclude_patterns, base: Dir.pwd)
        Array(paths).flat_map do |path|
          if File.directory?(path)
            directory_files(path, exclude_patterns, base: base)
          elsif File.file?(path) && path.end_with?(".rb")
            [path]
          else
            []
          end
        end
      end

      def directory_files(dir, exclude_patterns, base: Dir.pwd)
        reject_excluded(Dir.glob(File.join(dir, RUBY_GLOB)), exclude_patterns, base: base, root: dir)
      end

      # `exclude_patterns` are matched with `File.fnmatch?` WITHOUT `FNM_PATHNAME`, so `**`/`*` span separators
      # (the patterns behave like substring globs) — the exact semantics the Runner's directory glob applies.
      #
      # #1576 — a RELATIVE pattern is matched only against the file's path relative to `base` (the config file's
      # directory, or the working directory with no config), so the same file is excluded whether `paths:`
      # (absolute) or an argument (relative) named it, and a segment of the tree ABOVE `base` is never visible to
      # it. The pattern is also tried against `/<relative>`, because without `FNM_PATHNAME` the unanchored
      # `**/tmp/**` needs a leading `/` to match a top-level `tmp/x.rb`. A file outside `base` is matched by
      # absolute patterns only, unless it came from a directory argument (`root:`), which then serves as its base.
      # An ABSOLUTE pattern is matched only against the absolute path. Both the base and the file go through
      # `realpath` so a symlinked spelling (macOS `/tmp` vs `/private/tmp`) cannot make the relative spelling
      # vanish; absolute patterns also see the logical absolute spelling.
      def reject_excluded(file_list, exclude_patterns, base: Dir.pwd, root: nil)
        return file_list if exclude_patterns.empty?

        absolute_patterns, relative_patterns = exclude_patterns.partition { |pattern| pattern.start_with?("/") }
        bases = [real_directory(base)]
        bases << real_directory(root) if root
        real_dirs = {}
        file_list.reject do |path|
          excluded?(path, absolute_patterns, relative_patterns, bases, real_dirs)
        end
      end

      # `bases` is the project base, then (for a directory expansion) the directory argument itself: a directory
      # outside the project base is still matched relative to itself, never to anything above it.
      def excluded?(path, absolute_patterns, relative_patterns, bases, real_dirs)
        logical = File.absolute_path(path)
        real = real_file(logical, real_dirs)
        return true if absolute_patterns.any? { |pattern| [logical, real].any? { |s| File.fnmatch?(pattern, s) } }

        relative = relative_to_first(real, bases)
        return false unless relative

        relative_patterns.any? do |pattern|
          File.fnmatch?(pattern, relative) || File.fnmatch?(pattern, "/#{relative}")
        end
      end

      def relative_to_first(real, bases)
        bases.each do |base|
          prefix = base.end_with?("/") ? base : "#{base}/"
          return real.delete_prefix(prefix) if real.start_with?(prefix)
        end
        nil
      end

      def real_directory(dir)
        File.realpath(dir)
      rescue SystemCallError
        File.absolute_path(dir)
      end

      def real_file(absolute, real_dirs)
        dir = File.dirname(absolute)
        real_dir = real_dirs[dir] ||= real_directory(dir)
        File.join(real_dir, File.basename(absolute))
      end
    end
  end
end
