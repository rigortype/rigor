# frozen_string_literal: true

require_relative "../analysis/path_expansion"
require_relative "../rooted_glob"

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
      # word (`require_relative`) does not, and a computed name never does; nor do `require(` with the name on
      # the next line or `send(:require, "prime")`. A match on a whole-line comment ({#commented?}) does not
      # count, so commenting a require out changes nothing. Otherwise the match is textual and leans toward
      # loading: a `require "prime"` in a trailing comment, a heredoc or an `=begin` block counts. That direction
      # only loads the gem's own signatures, and `RbsLoader` still drops them when they cost the environment
      # anything.
      PATTERN = /(?:(?<![\w.$@])|(?<=Kernel\.))require[ \t]*\(?[ \t]*(["'])(#{FEATURE_ALTERNATION})\1/

      # Issue #2174 — the gems Ruby 4.0 bundles (its `gems/bundled_gems` list, which an installation does not
      # keep): installed beside the interpreter, but loaded only by an explicit `require`. Gems installed later
      # into the same directory are deliberately not read from it.
      BUNDLED_GEMS = %w[
        abbrev base64 benchmark bigdecimal csv debug drb fiddle getoptlong irb logger matrix minitest mutex_m
        net-ftp net-imap net-pop net-smtp nkf observer ostruct power_assert prime pstore racc rake rbs rdoc readline
        reline repl_type_completor resolv-replace rexml rinda rss syslog test-unit typeprof win32ole
      ].freeze

      # Issue #2174 — the first path segments of the features Ruby ships: the `.rb` files and directories of the
      # interpreter's library directory, the extensions and directories of its architecture directory, and the
      # bundled gems' names (`net-ftp` → `net`). Read once, at load time and on the main Ractor, since
      # `RbConfig::CONFIG` is not shareable; empty when the directories cannot be read.
      SHIPPED_SEGMENTS = begin
        require "rbconfig"
        segments = Set.new
        [RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["archdir"]].compact.each do |dir|
          next unless File.directory?(dir)

          Dir.children(dir).each { |entry| segments << entry.sub(/\.(?:rb|so|bundle|dll)\z/, "") }
        end
        BUNDLED_GEMS.each { |name| segments << name.split("-").first }
        segments.to_set(&:freeze).freeze
      rescue StandardError
        Set.new.freeze
      end

      # A `require` of any literal feature, read as {PATTERN} reads one; {.features_of} keeps those Ruby ships.
      ANY_FEATURE = %r{(?:(?<![\w.$@])|(?<=Kernel\.))require[ \t]*\(?[ \t]*(["'])([\w-]+(?:/[\w-]+)*)\1}

      module_function

      # The features a run over `configuration` requires: every file under the configured paths, plus
      # `extra_files` (a run's own targets or a probe's file, which may lie outside them). The scan does not
      # depend on which files a run checks, so `rigor check lib/a.rb`, a probe on `lib/a.rb` and the language
      # server all see a `require "prime"` in `lib/b.rb`. Fails soft to no features.
      #
      # @param sources — path => source text, read in place of that path's file (an editor buffer).
      def for_configuration(configuration, extra_files = [], sources: {})
        files = Analysis::PathExpansion.ruby_files(configuration.paths, configuration.exclude_patterns,
                                                   base: configuration.exclude_base)
        scan(files + Array(extra_files).map(&:to_s), sources: sources,
                                                     sig_paths: configured_sig_paths(configuration))
      rescue StandardError
        []
      end

      # The project signature roots the environment loads: the configured `signature_paths:`, else `./sig` when it
      # exists (`Environment.project_signature_roots`, which this leaf file does not load).
      def configured_sig_paths(configuration)
        configured = configuration.signature_paths
        return Array(configured).map(&:to_s) if configured

        File.directory?("sig") ? ["sig"] : []
      end

      # @param files — source paths (Strings or Pathnames); an unreadable one contributes nothing.
      # @param sources — path => source text, scanned instead of the file; its paths are scanned even when
      #   `files` does not list them.
      # @param sig_paths — the project's signature roots, whose `.rbs` declaration headers count as the project's
      #   own names ({.relevant}).
      # @return the sorted, frozen features some file requires, a shipped one kept only when {.relevant}.
      def scan(files, sources: {}, sig_paths: [])
        sources = sources.to_h { |path, text| [File.expand_path(path.to_s), text] }
        paths = (Array(files).map { |path| source_key(File.expand_path(path.to_s), sources) } + sources.keys).uniq
        found = Set.new
        names = Set.new
        paths.each do |path|
          features, declared = sources.key?(path) ? scan_source(sources[path]) : memoized_scan_in(path)
          found.merge(features)
          names.merge(declared)
        end
        prune_memo(paths)
        relevant(found, names.merge(sig_names(sig_paths))).sort.freeze
      end

      # @return path (absolute) => `[features, declared names]` ({.scan_source}) for every file under the
      #   configured paths that has either. A long-lived reader (the language server) keeps this, overlays its open
      #   buffers and passes the union to {.relevant}.
      def feature_files(configuration)
        listed = Analysis::PathExpansion.ruby_files(configuration.paths, configuration.exclude_patterns,
                                                    base: configuration.exclude_base)
        files = listed.map { |path| File.expand_path(path.to_s) }
        result = files.each_with_object({}) do |path, acc|
          scanned = memoized_scan_in(path)
          acc[path] = scanned unless scanned.all?(&:empty?)
        end
        prune_memo(files)
        result
      rescue StandardError
        {}
      end

      # Issue #2174 — `features` with each shipped feature kept only when one of `names` (constant names the
      # project's source or signatures declare a class or module under) is a root the feature's library declares
      # ({RubyLibraryRoots}). Only such a feature can open a class (`RbsLoader#ruby_library_reopen?` asks it of a
      # class every declaration of which is the project's), so dropping the rest changes no diagnostic, and keeps a
      # `require "json"` edit in a project that reopens no library class out of the incremental snapshot's
      # fingerprint and the language server's environment key. The listed features ({VENDORED_DIRS}) are kept.
      def relevant(features, names)
        return features.to_a if features.all? { |feature| VENDORED_DIRS.key?(feature) }

        segments = names.empty? ? EMPTY_SEGMENTS : library_segments(names)
        features.select { |feature| VENDORED_DIRS.key?(feature) || segments.include?(feature.split("/").first) }
      end

      # The feature segments of the libraries that declare one of `names` as a root. Loaded lazily: the roots read
      # the `rbs` stdlib tree, which a run with no shipped `require` never needs.
      def library_segments(names)
        require_relative "ruby_library_roots"
        roots = RubyLibraryRoots.shared
        names.each_with_object(Set.new) { |name, acc| acc.merge(roots.fetch(name, EMPTY_SEGMENTS)) }
      end

      EMPTY_SEGMENTS = [].freeze

      # The constant names the `.rbs` files under `sig_paths` declare a class or module under.
      def sig_names(sig_paths)
        Array(sig_paths).each_with_object(Set.new) do |root, acc|
          next unless File.directory?(root.to_s)

          RootedGlob.glob(root.to_s, "**/*.rbs").each do |path|
            acc.merge(declared_names(File.binread(path)))
          rescue SystemCallError, IOError
            next
          end
        end
      end

      # Paths are compared expanded, so a relative `--instead-of=lib/a.rb` replaces the configured
      # `/project/lib/a.rb`; a source whose real path matches (a symlinked directory) replaces it too. The real
      # path is asked only for a file that shares a source's basename, so a scan does not resolve every path.
      def source_key(path, sources)
        return path if sources.empty? || sources.key?(path)

        candidates = sources.keys.select { |key| File.basename(key) == File.basename(path) }
        return path if candidates.empty?

        real = real_path(path)
        candidates.find { |key| real_path(key) == real } || path
      end

      def real_path(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      # One run scans the same files more than once (the incremental snapshot fingerprint, then the environment
      # build; a long-lived language server on every rebuild), so on the main Ractor each file's answer is kept
      # against its stat and the file is re-read only when the stat moved. A non-main Ractor may not touch the
      # module's state and reads the file every time.
      def memoized_scan_in(path)
        return scan_in(path) unless Ractor.current == Ractor.main

        stat = File.stat(path)
        stamp = [stat.mtime.to_r, stat.ctime.to_r, stat.size, stat.ino]
        memo = (@memo ||= {})
        cached = memo[path]
        return cached.last if cached && cached.first == stamp

        scanned = scan_in(path)
        memo[path] = [stamp, scanned]
        scanned
      rescue SystemCallError
        NOTHING
      end

      NOTHING = [[].freeze, [].freeze].freeze

      # Keeps the memo to the files the latest scan was asked about, so a long-lived language server holds one
      # entry per project file rather than one per file it ever saw.
      def prune_memo(paths)
        return unless Ractor.current == Ractor.main && @memo && @memo.size > paths.size

        keep = paths.to_set
        @memo.select! { |path, _| keep.include?(path) }
      end

      # @return `[features, declared names]` for one file ({.scan_source}).
      def scan_in(path)
        scan_source(File.binread(path))
      rescue SystemCallError, IOError
        NOTHING
      end

      # @return `[features, declared names]`: what {.features_of} reads, and the constant names a `class` or
      # `module` header in `source` spells, each segment on its own (`class Net::SMTP` gives `Net` and `SMTP`).
      def scan_source(source)
        [features_of(source), declared_names(source)].freeze
      end

      # A header on a line of its own, or inside a comment (an rbs-inline `# @rbs!` block declares
      # `#   class Matrix`). Over-matching a comment only keeps more features.
      HEADER = /^[ \t]*(?:#[ \t]*)?(?:class|module)[ \t]+(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)/

      def declared_names(source)
        bytes = source.b
        return [] unless bytes.include?("class") || bytes.include?("module")

        bytes.scan(HEADER).flat_map { |(name)| name.split("::") }
             .uniq.map { |name| name.dup.force_encoding(Encoding::UTF_8).freeze }.freeze
      end

      # @return the features `source` requires: the listed ones ({VENDORED_DIRS}), and, for issue #2174, every
      # feature Ruby ships ({SHIPPED_SEGMENTS}), which `RbsLoader#ruby_library_reopen?` reads to tell a reopened
      # library class from a project class of the same name. Only the listed ones become library tokens.
      def features_of(source)
        # A plain substring test first: a file with no `require` at all is the common case, and it is far cheaper
        # than the regexp on a file that has none.
        return [] unless source.include?("require")

        bytes = source.b
        named = []
        position = 0
        while (match = ANY_FEATURE.match(bytes, position))
          named << match[2] unless commented?(bytes, match.begin(0))
          position = match.end(0)
        end
        # The table's own frozen keys, and frozen copies of the rest, so the result is shareable across Ractors
        # whatever the source's encoding.
        listed = VENDORED_DIRS.each_key.select { |feature| named.include?(feature) }
        shipped = named.select { |feature| SHIPPED_SEGMENTS.include?(feature.split("/").first) }
        (listed + shipped.map { |feature| feature.dup.force_encoding(Encoding::UTF_8).freeze }).uniq
      end

      # Whether the match at `offset` sits on a line whose first non-blank character is `#`: a whole-line comment.
      # Deliberately narrower than "after a `#`": a `#` later on a line may be inside `?#`, `%q(#)`, `%w[a#b]`,
      # a regexp or a string continued from an earlier line, and reading it as a comment would drop a real
      # require — a false `call.undefined-method` on every call into the feature. A trailing comment
      # (`p 1 # require "prime"`) therefore still counts, which only loads the gem's own signatures.
      def commented?(bytes, offset)
        line_start = offset.zero? ? 0 : (bytes.rindex("\n", offset - 1) || -1) + 1
        bytes.byteslice(line_start, offset - line_start).lstrip.start_with?("#")
      end

      # The library tokens for `features` and for any listed feature the configuration's `libraries:` names.
      def tokens(features, configured_libraries)
        configured = Array(configured_libraries).map(&:to_s).select { |name| VENDORED_DIRS.key?(name) }
        listed = Array(features).select { |feature| VENDORED_DIRS.key?(feature) }
        (listed | configured).sort.map { |feature| token(feature) }
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
