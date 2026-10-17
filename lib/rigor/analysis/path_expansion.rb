# frozen_string_literal: true

require_relative "../rooted_glob"

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
        reject_excluded(RootedGlob.glob(dir, RUBY_GLOB), exclude_patterns, base: base)
      end

      # `exclude_patterns` are matched with `File.fnmatch?` WITHOUT `FNM_PATHNAME`, so `**`/`*` span separators
      # (the patterns behave like substring globs) — the exact semantics the Runner's directory glob applies.
      #
      # #1576 — a RELATIVE pattern (a leading `./` is ignored) is matched against the file's path relative to
      # `base` (the config file's directory, or the working directory with no config), so the same file is
      # excluded whether `paths:` (absolute) or an argument (relative) named it.
      #
      # Two spellings are tried. The LOGICAL one (the path as given, against the logical base) counts only when
      # the file lies inside the base; it is what lets a symlinked `lib` match `lib/gen/**`. The REALPATH one
      # (realpath of the file against realpath of the base) is the only one used for a file outside the base, and
      # it also catches a base or file spelled through a different symlink root (macOS `/tmp` vs `/private/tmp`).
      # Neither shows a directory name above the base: a file outside it comes out as `../…`, so `**/tmp/**`
      # cannot exclude a project merely located under a `tmp/`, while `**/vendor/bundle/**` still reaches
      # `../other/vendor/bundle/x.rb`. The pattern is also tried against `/<relative>`, because without
      # `FNM_PATHNAME` the unanchored `**/tmp/**` needs a leading `/` to match a top-level `tmp/x.rb` (and `*`
      # never matches a leading `.`, as in `../other`). A pattern starting with `.` therefore also matches files
      # outside the base. An ABSOLUTE pattern is matched only against the absolute path (logical, then real).
      def reject_excluded(file_list, exclude_patterns, base: Dir.pwd)
        return file_list if exclude_patterns.empty?

        absolute_patterns, relative_patterns = exclude_patterns.partition { |pattern| pattern.start_with?("/") }
        relative_patterns = relative_patterns.map { |pattern| pattern.sub(%r{\A(?:\./+)+}, "") }
        logical_base = File.absolute_path(base)
        context = { cwd: Dir.pwd, base: logical_base, real_base: real_directory(logical_base), real_dirs: {} }
        file_list.reject { |path| excluded?(path, absolute_patterns, relative_patterns, context) }
      end

      def excluded?(path, absolute_patterns, relative_patterns, context)
        logical = File.absolute_path(path, context.fetch(:cwd))
        base = context.fetch(:base)
        inside = logical.start_with?("#{base}/")
        return true if inside && matches_relative?(relative_patterns, logical.byteslice((base.bytesize + 1)..))
        return true if absolute_patterns.any? { |pattern| File.fnmatch?(pattern, logical) }

        real = real_file(logical, context.fetch(:real_dirs))
        return false if real == logical && inside && context.fetch(:real_base) == base

        matches_relative?(relative_patterns, relative_path(real, context.fetch(:real_base))) ||
          (real != logical && absolute_patterns.any? { |pattern| File.fnmatch?(pattern, real) })
      end

      def relative_path(absolute, base)
        return absolute.byteslice((base.bytesize + 1)..) if absolute.start_with?("#{base}/")

        Pathname.new(absolute).relative_path_from(Pathname.new(base)).to_s
      end

      def matches_relative?(patterns, relative)
        candidates = [relative, "/#{relative}"]
        patterns.any? { |pattern| candidates.any? { |candidate| File.fnmatch?(pattern, candidate) } }
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
