# frozen_string_literal: true

module Rigor
  class Environment
    # Issue #1700 — vendored signatures that load only when the project's own source requires the feature. A
    # `data/vendored_gem_sigs/` directory loads for every project, which is safe for a gem that owns its
    # namespace (`PG::Connection`) and unsafe for one that reopens core classes or claims a short top-level name.
    # `prime` does both: it declares `class Prime` and adds `Integer#prime?`, and with it loaded unconditionally a
    # project's own `class Prime` with a zero-argument `prime?` drew a false `call.wrong-arity` against the gem's
    # `(Integer, ?generator)`. Such a directory is listed in {VENDORED_DIRS} and loads only when some source
    # file in the run carries a literal `require "<feature>"`.
    #
    # The decision travels as a library token ({token}) inside the environment's library list, so every
    # consumer that already keys on that list sees it without plumbing of its own: the RBS environment cache
    # key (`Cache::RbsDescriptor.libraries_entry`), the env-cache producer that rebuilds from
    # `RbsLoader#libraries`, and the run-result key built from the loader's descriptor. The ADR-87 boot-slimming
    # probe reconstructs the list from configuration alone and so never carries a token: for a project that
    # requires a listed feature it misses and the full path serves the run, which forgoes the fast lane and
    # never serves a wrong answer.
    #
    # A leaf file (no engine requires), for the reason `default_libraries.rb` is one: the incremental snapshot
    # fingerprint reads it without building an environment.
    module RequiredFeatures
      # Required feature => `data/vendored_gem_sigs/` directory basename. A feature the project's configuration
      # names under `libraries:` is left to RBS library resolution and never vendored, so the two cannot both
      # declare it.
      VENDORED_DIRS = { "prime" => "prime" }.freeze

      TOKEN_PREFIX = "rigor-vendored:"

      # A literal `require "prime"` / `require 'prime'` that starts a line or follows a `;`, with or without
      # parentheses. `require_relative`, a computed name, and a mention in a comment do not match: the gate reads
      # what the source says, never what it might load.
      FEATURE_ALTERNATION = VENDORED_DIRS.keys.map { |feature| Regexp.escape(feature) }.join("|").freeze
      private_constant :FEATURE_ALTERNATION
      PATTERN = /(?:^|;)[ \t]*require[ \t]*\(?[ \t]*(["'])(#{FEATURE_ALTERNATION})\1/

      module_function

      # @param files — source paths (Strings or Pathnames); an unreadable one contributes nothing.
      # @return the sorted, frozen features some file requires.
      def scan(files)
        found = Set.new
        Array(files).each do |path|
          break if found.size == VENDORED_DIRS.size

          found.merge(memoized_features_in(path.to_s))
        end
        found.to_a.sort.freeze
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

      # @return the features one file requires.
      def features_in(path)
        source = File.binread(path)
        # A plain substring test first: almost no file mentions any listed feature, and it is far cheaper than
        # the regexp on a file that does not.
        return [] unless VENDORED_DIRS.each_key.any? { |feature| source.include?(feature) }

        source.scan(PATTERN).map(&:last).uniq
      rescue SystemCallError, IOError
        []
      end

      # The library tokens for `features`, less any the configuration's own `libraries:` names.
      def tokens(features, configured_libraries)
        configured = Array(configured_libraries).map(&:to_s)
        Array(features).reject { |feature| configured.include?(feature) }.map { |feature| token(feature) }
      end

      def token(feature)
        "#{TOKEN_PREFIX}#{feature}"
      end

      # The vendored directory basenames a library list activates.
      def active_dirs(library_names)
        library_names.filter_map do |name|
          next unless name.start_with?(TOKEN_PREFIX)

          VENDORED_DIRS[name.delete_prefix(TOKEN_PREFIX)]
        end
      end

      # Whether `dir_basename` is one of the gated directories.
      def gated_dir?(dir_basename)
        VENDORED_DIRS.value?(dir_basename)
      end
    end
  end
end
