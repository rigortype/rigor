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
      def ruby_files(paths, exclude_patterns)
        Array(paths).flat_map do |path|
          if File.directory?(path)
            directory_files(path, exclude_patterns)
          elsif File.file?(path) && path.end_with?(".rb")
            [path]
          else
            []
          end
        end
      end

      def directory_files(dir, exclude_patterns)
        reject_excluded(Dir.glob(File.join(dir, RUBY_GLOB)), exclude_patterns)
      end

      # `exclude_patterns` are matched with `File.fnmatch?` WITHOUT `FNM_PATHNAME`, so `**`/`*` span separators
      # (the patterns behave like substring globs) — the exact semantics the Runner's directory glob applies.
      #
      # A file is tested under every spelling of the same path (#1576): as given, relative to the working
      # directory (the project root, where `.rigor.yml` is discovered), and absolute. `.rigor.yml`'s `paths:`
      # load as absolute, an argument may be spelled relatively, and a pattern written against either must
      # exclude the same files.
      def reject_excluded(file_list, exclude_patterns)
        return file_list if exclude_patterns.empty?

        root = Dir.pwd
        file_list.reject do |path|
          spellings = path_spellings(path, root)
          exclude_patterns.any? { |pattern| spellings.any? { |spelling| File.fnmatch?(pattern, spelling) } }
        end
      end

      def path_spellings(path, root)
        absolute = File.absolute_path(path, root)
        spellings = [path, absolute]
        prefix = root.end_with?("/") ? root : "#{root}/"
        spellings << absolute.delete_prefix(prefix) if absolute.start_with?(prefix)
        spellings.uniq
      end
    end
  end
end
