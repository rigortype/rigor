# frozen_string_literal: true

require "rbs"
require "rbconfig"
require_relative "missing_gem_constant_index"
require_relative "required_features"
require_relative "../rooted_glob"

module Rigor
  class Environment
    # Issue #2174 — which library Ruby ships declares each root constant name. Three sources are read, and no others:
    #
    # - every library of the `rbs` gem's `stdlib/` tree, loaded into this run or not, read from its `.rbs` files
    #   (`net-http` declares `Net`);
    # - every top-level `.rb` file of the interpreter's library directory (`RbConfig::CONFIG["rubylibdir"]`), the
    #   default gems' and the standard library's entry files, read from their top-level declarations;
    # - the entry file of each gem Ruby bundles ({RequiredFeatures::BUNDLED_GEMS}), found under the interpreter's
    #   gem directory. A gem installed there later is not one of them and is not read.
    #
    # Each root maps to the first path segments of the features that load it (`Matrix` → `matrix`, `Net` → `net`),
    # which {RbsLoader#ruby_library_reopen?} intersects with the features the project's source requires
    # ({RequiredFeatures.features_of}).
    #
    # Ownership is read, never guessed by camelizing a library name, for the reason {MissingGemConstantIndex}
    # gives; that module's reader parses the `.rb` entry files. No library code runs. Everything fails open to
    # "no library", which keeps the pre-#2174 reading. Core names (`Array`, `Kernel`) appear too, harmlessly:
    # core signatures always load, so no project-only class carries one.
    #
    # The directories are resolved at load time, on the main Ractor: `RbConfig::CONFIG` and `Gem.default_dir`
    # read non-shareable constants and raise `Ractor::IsolationError` inside a pool worker. The scan itself runs
    # lazily (about 0.1 s), memoised per loader, and only for a class about to be reported.
    module RubyLibraryRoots
      STDLIB_ROOT = begin
        ::RBS::Repository::DEFAULT_STDLIB_ROOT.to_s.dup.freeze
      rescue StandardError
        nil
      end

      RUBY_LIB_DIR = begin
        RbConfig::CONFIG["rubylibdir"].to_s.dup.freeze
      rescue StandardError
        nil
      end

      RUBY_GEMS_DIR = begin
        File.join(Gem.default_dir, "gems").freeze
      rescue StandardError
        nil
      end

      module_function

      # {.build}, built once per process on the main Ractor, where the language server and the incremental
      # snapshot fingerprint ask it repeatedly; a non-main Ractor may not keep module state and builds its own.
      def shared
        return build unless Ractor.current == Ractor.main

        @shared ||= build
      end

      # The frozen map of root constant name to the frozen set of feature segments that load it.
      def build
        roots = Hash.new { |hash, key| hash[key] = Set.new }
        stdlib_roots(roots)
        ruby_lib_roots(roots)
        bundled_gem_roots(roots)
        roots.each_value(&:freeze)
        roots.default_proc = nil
        roots.freeze
      end

      def stdlib_roots(roots)
        return if STDLIB_ROOT.nil? || !File.directory?(STDLIB_ROOT)

        Dir.children(STDLIB_ROOT).each do |library|
          segment = library.split("-").first
          RootedGlob.glob(File.join(STDLIB_ROOT, library), "*/**/*.rbs").each do |path|
            stdlib_file_roots(path).each { |root| roots[root] << segment }
          end
        end
      end

      def stdlib_file_roots(path)
        _, _, decls = ::RBS::Parser.parse_signature(File.read(path))
        decls.filter_map { |decl| root_of(decl) if named_declaration?(decl) }
      rescue StandardError
        []
      end

      def ruby_lib_roots(roots)
        return if RUBY_LIB_DIR.nil? || !File.directory?(RUBY_LIB_DIR)

        RootedGlob.glob(RUBY_LIB_DIR, "*.rb").each do |path|
          segment = File.basename(path, ".rb")
          MissingGemConstantIndex.top_level_root_constants(path).each { |root| roots[root] << segment }
        end
      end

      def bundled_gem_roots(roots)
        return if RUBY_GEMS_DIR.nil? || !File.directory?(RUBY_GEMS_DIR)

        Dir.children(RUBY_GEMS_DIR).each do |basename|
          gem_name = basename[/\A(.+?)-\d/, 1]
          next if gem_name.nil? || !RequiredFeatures::BUNDLED_GEMS.include?(gem_name)

          segment = gem_name.split("-").first
          MissingGemConstantIndex.entry_files(File.join(RUBY_GEMS_DIR, basename), gem_name).each do |path|
            MissingGemConstantIndex.top_level_root_constants(path).each { |root| roots[root] << segment }
          end
        end
      end

      def named_declaration?(decl)
        decl.is_a?(::RBS::AST::Declarations::Class) || decl.is_a?(::RBS::AST::Declarations::Module)
      end

      def root_of(decl)
        decl.name.to_s.delete_prefix("::").split("::").first
      end
    end
  end
end
