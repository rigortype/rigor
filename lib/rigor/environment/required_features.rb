# frozen_string_literal: true

require_relative "../analysis/path_expansion"

module Rigor
  class Environment
    # Issue #1700 — vendored signatures that load only when the project's own source requires the feature. A
    # `data/vendored_gem_sigs/` directory loads for every project, which is safe for a gem that owns its
    # namespace (`PG::Connection`) and unsafe for one that reopens core classes or claims a short top-level name.
    # `prime` does both: it declares `class Prime` and adds `Integer#prime?`, and with it loaded unconditionally a
    # project's own `class Prime` with a zero-argument `prime?` drew a false `call.wrong-arity` against the gem's
    # `(Integer, ?generator)`. Such a directory is listed in {VENDORED_DIRS} and loads only when some project
    # source file requires the feature ({PATTERN}), or the configuration lists it under `libraries:`.
    #
    # The decision travels as a library token ({token}) inside the environment's library list, so every
    # consumer that already keys on that list sees it without plumbing of its own: the RBS environment cache
    # key (`Cache::RbsDescriptor.libraries_entry`), the env-cache producer that rebuilds from
    # `RbsLoader#libraries`, and the run-result key built from the loader's descriptor. The ADR-87 boot-slimming
    # probe reconstructs the list from configuration alone and so never carries a token: for a project that
    # requires a listed feature it misses and the full path serves the run, which forgoes the fast lane and
    # never serves a wrong answer. Whether a token's directory then loads is `RbsLoader`'s decision, made
    # against what the environment actually holds (`RbsLoader.gated_dir_loads?`).
    #
    # A leaf file (no engine requires), for the reason `default_libraries.rb` is one: the incremental snapshot
    # fingerprint reads it without building an environment.
    module RequiredFeatures
      # Required feature => `data/vendored_gem_sigs/` directory basename.
      VENDORED_DIRS = { "prime" => "prime" }.freeze

      TOKEN_PREFIX = "rigor-vendored:"

      FEATURE_ALTERNATION = VENDORED_DIRS.keys.map { |feature| Regexp.escape(feature) }.join("|").freeze
      private_constant :FEATURE_ALTERNATION

      # A `require` call naming a listed feature as a string literal, with or without parentheses: the bare call
      # and `Kernel.require` count, a `require` that follows any other `.` (`obj.require`) or is part of a longer
      # word (`require_relative`) does not, and a computed name never does. A match after a `#` line comment
      # marker on its line ({#commented?}) does not count, so a mention in a comment changes nothing. Otherwise
      # the match is textual and leans toward loading: a `require "prime"` inside a heredoc or an `=begin` block
      # counts. That direction only loads the gem's own signatures, and `RbsLoader` still declines them when the
      # project declares a clashing member itself.
      PATTERN = /(?:(?<![\w.$@])|(?<=Kernel\.))require[ \t]*\(?[ \t]*(["'])(#{FEATURE_ALTERNATION})\1/

      QUOTES = ["\"", "'"].freeze
      private_constant :QUOTES

      module_function

      # The features a run over `configuration` requires: every file under the configured paths, plus
      # `extra_files` (a run's own targets or a probe's file, which may lie outside them). The scan does not
      # depend on which files a run checks, so `rigor check lib/a.rb`, a probe on `lib/a.rb` and the language
      # server all see a `require "prime"` in `lib/b.rb`. Fails soft to no features.
      #
      # @param sources — path => source text, read in place of that path's file (an editor buffer).
      def for_configuration(configuration, extra_files = [], sources: {})
        files = Analysis::PathExpansion.ruby_files(configuration.paths, configuration.exclude_patterns)
        scan(files + Array(extra_files).map(&:to_s), sources: sources)
      rescue StandardError
        []
      end

      # @param files — source paths (Strings or Pathnames); an unreadable one contributes nothing.
      # @param sources — path => source text, scanned instead of the file; its paths are scanned even when
      #   `files` does not list them.
      # @return the sorted, frozen features some file requires.
      def scan(files, sources: {})
        paths = (Array(files).map(&:to_s) + sources.keys.map(&:to_s)).uniq
        found = Set.new
        paths.each do |path|
          break if found.size == VENDORED_DIRS.size

          found.merge(sources.key?(path) ? features_of(sources[path]) : memoized_features_in(path))
        end
        prune_memo(paths)
        found.to_a.sort.freeze
      end

      # @return path (absolute) => the features that file requires, for every file under the configured paths
      #   that requires any. A long-lived reader (the language server) keeps this and overlays its open buffers.
      def feature_files(configuration)
        files = Analysis::PathExpansion.ruby_files(configuration.paths, configuration.exclude_patterns)
        result = files.each_with_object({}) do |path, acc|
          features = memoized_features_in(path.to_s)
          acc[File.expand_path(path.to_s)] = features unless features.empty?
        end
        prune_memo(files.map(&:to_s))
        result
      rescue StandardError
        {}
      end

      # One run scans the same files more than once (the incremental snapshot fingerprint, then the environment
      # build; a long-lived language server on every rebuild), so on the main Ractor each file's answer is kept
      # against its stat and the file is re-read only when the stat moved. A non-main Ractor may not touch the
      # module's state and reads the file every time.
      def memoized_features_in(path)
        return features_in(path) unless Ractor.current == Ractor.main

        stat = File.stat(path)
        stamp = [stat.mtime.to_r, stat.ctime.to_r, stat.size, stat.ino]
        memo = (@memo ||= {})
        cached = memo[path]
        return cached.last if cached && cached.first == stamp

        features = features_in(path)
        memo[path] = [stamp, features]
        features
      rescue SystemCallError
        []
      end

      # Keeps the memo to the files the latest scan was asked about, so a long-lived language server holds one
      # entry per project file rather than one per file it ever saw.
      def prune_memo(paths)
        return unless Ractor.current == Ractor.main && @memo && @memo.size > paths.size

        keep = paths.to_set
        @memo.select! { |path, _| keep.include?(path) }
      end

      # @return the features one file requires.
      def features_in(path)
        features_of(File.binread(path))
      rescue SystemCallError, IOError
        []
      end

      # @return the features `source` requires.
      def features_of(source)
        # A plain substring test first: almost no file mentions any listed feature, and it is far cheaper than
        # the regexp on a file that does not.
        return [] unless VENDORED_DIRS.each_key.any? { |feature| source.include?(feature) }

        bytes = source.b
        named = []
        position = 0
        while (match = PATTERN.match(bytes, position))
          named << match[2] unless commented?(bytes, match.begin(0))
          position = match.end(0)
        end
        # The table's own frozen keys, so the result is shareable across Ractors whatever the source's encoding.
        VENDORED_DIRS.each_key.select { |feature| named.include?(feature) }
      end

      # Whether the text before `offset` on its line holds a `#` outside a string literal: the first `#` not
      # inside single or double quotes starts a comment. Quote tracking is per line and ignores `%q` forms and
      # heredocs, which can only make a commented match count, never drop a real one.
      def commented?(bytes, offset)
        return false if offset.zero?

        line_start = (bytes.rindex("\n", offset - 1) || -1) + 1
        quote = nil
        escaped = false
        bytes.byteslice(line_start, offset - line_start).each_char do |char|
          if quote
            if escaped then escaped = false
            elsif char == "\\" then escaped = true
            elsif char == quote then quote = nil
            end
          elsif QUOTES.include?(char) then quote = char
          elsif char == "#" then return true
          end
        end
        false
      end

      # The library tokens for `features` and for any listed feature the configuration's `libraries:` names.
      def tokens(features, configured_libraries)
        configured = Array(configured_libraries).map(&:to_s).select { |name| VENDORED_DIRS.key?(name) }
        (Array(features) | configured).sort.map { |feature| token(feature) }
      end

      def token(feature)
        "#{TOKEN_PREFIX}#{feature}"
      end

      # The feature a library token names, or nil for an ordinary library name.
      def feature_of_token(name)
        name = name.to_s
        name.start_with?(TOKEN_PREFIX) ? name.delete_prefix(TOKEN_PREFIX) : nil
      end

      # The vendored directory basenames a library list activates.
      def active_dirs(library_names)
        library_names.filter_map { |name| VENDORED_DIRS[feature_of_token(name)] }
      end

      # Whether `dir_basename` is one of the gated directories.
      def gated_dir?(dir_basename)
        VENDORED_DIRS.value?(dir_basename)
      end

      # The feature a gated directory loads for.
      def feature_for_dir(dir_basename)
        VENDORED_DIRS.key(dir_basename)
      end
    end
  end
end
