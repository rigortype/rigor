# frozen_string_literal: true

require "yaml"

require_relative "../config_path"

module Rigor
  class Environment
    # `rbs collection install` awareness (O4 Layer 3 slice 2, implemented).
    #
    # When the target project has been set up with `rbs collection install` (the standard RBS-ecosystem flow
    # for pulling community RBS from https://github.com/ruby/gem_rbs_collection), a
    # `rbs_collection.lock.yaml` records the resolved (gem, version, source) triples and
    # `.gem_rbs_collection/<name>/ <version>/` carries the actual `.rbs` files. This module parses the
    # lockfile and returns the per-gem RBS directory paths so they can be appended to `RbsLoader`'s
    # `signature_paths:`.
    #
    # The discovery is intentionally a pure file-system + YAML walk — no Bundler API call, no network
    # access. Failure modes (missing lockfile, malformed YAML, missing collection directory) silently
    # degrade to an empty list.
    module RbsCollectionDiscovery
      # `stdlib`-typed entries (`source: { type: stdlib }`) name a library rbs ships under its own `stdlib/`, and
      # produce no directory under the collection root, so {.discover} never returns one. Issue #2946 — they are
      # loaded all the same, as the `rbs` CLI's `EnvironmentLoader#add_collection` loads them: as RBS LIBRARIES.
      # {.stdlib_library_names} lists them, and `Environment::BaseLibraries.resolve` appends them to the library list,
      # which is de-duplicated, so an entry `DEFAULT_LIBRARIES` already names is not loaded twice. A collection
      # gem that subclasses one (actionview's `NodeParser < ::Ripper`) then builds. An unknown name is dropped by
      # the loader's `has_library?` filter, as a `libraries:` name is, and `ConfigAudit` reports it. The other
      # documented source types — `git` (the gem_rbs_collection repo), `rubygems` (sigs lifted from a gem's
      # bundled `sig/`), and `local` (a user-managed RBS dir) — all produce a directory under the collection root
      # and are admitted by {.discover}.
      #
      # The `source.type` filter alone is NOT sufficient: gems that were extracted from Ruby's stdlib into
      # standalone default gems (e.g. `cgi`, `logger`, `base64`, `csv`, `bigdecimal`) are published in
      # `ruby/gem_rbs_collection` under a `git` source type, yet rigor ALSO loads them from its bundled
      # stdlib via `DEFAULT_LIBRARIES`. Loading both copies triggers the very
      # `RBS::DuplicatedDeclarationError` this module exists to avoid (observed on a Rails 8 app:
      # `.gem_rbs_collection/ cgi/0.5/` vs the bundled `stdlib/cgi`). The `skip_gem_names:` parameter lets
      # the caller pass the set of library names rigor already loads so those gems are dropped regardless of
      # `source.type`.
      SKIPPED_SOURCE_TYPES = Set["stdlib"].freeze

      DEFAULT_COLLECTION_PATH = ".gem_rbs_collection"
      private_constant :DEFAULT_COLLECTION_PATH

      # @param lockfile_path — explicit path to `rbs_collection.lock.yaml`. When `nil`,
      #   falls back to `auto_detect` if `auto_detect:` is true.
      # @param project_root — resolution base for relative `lockfile_path:` and the auto-detect
      #   search.
      # @param auto_detect — when true and `lockfile_path:` is nil, look for
      #   `<project_root>/rbs_collection.lock.yaml`.
      # @param skip_gem_names — gem names rigor already loads from its bundled
      #   stdlib (the merged `DEFAULT_LIBRARIES + libraries:` set). Entries whose `name` is in this set are
      #   dropped regardless of `source.type` to avoid `RBS::DuplicatedDeclarationError` on
      #   stdlib-extracted default gems. Defaults to empty.
      # @return every `<collection_path>/<gem-name>/<gem-version>/` directory listed in the
      #   lockfile whose entry has a non-skipped source type, whose `name` is not in `skip_gem_names:`, and
      #   whose directory exists on disk. Returns `[]` when no lockfile is resolvable, when the YAML is
      #   unreadable, or when the collection path doesn't exist.
      def self.discover(lockfile_path:, project_root: Dir.pwd, auto_detect: true, skip_gem_names: [])
        resolved = resolve_lockfile_path(
          lockfile_path: lockfile_path,
          project_root: project_root,
          auto_detect: auto_detect
        )
        return [] if resolved.nil?

        data = read_lockfile_yaml(resolved)
        return [] if data.nil?

        collection_root = resolve_collection_root(resolved, data)
        return [] unless collection_root.directory?

        gem_paths_from(collection_root, data, skip_gem_names.to_set)
      end

      # The absolute path a configured `lockfile:` names, whether or not the file exists. The one place the
      # setting is expanded (a leading `~/` is the home directory), shared by `resolve_lockfile_path` and
      # by `WriteGuard`, which must watch the very path the run reads.
      def self.configured_lockfile_path(lockfile_path, project_root = Dir.pwd)
        Rigor::ConfigPath.absolute(lockfile_path.to_s, project_root)
      end

      # Issue #2946 — the `name` of every `source: { type: stdlib }` entry in the lockfile, in lockfile order and
      # de-duplicated, whether or not rbs ships that library: the caller loads them as RBS libraries, and the
      # loader's `has_library?` filter drops an unknown one. Unlike {.discover}, the collection directory need not
      # exist, since a stdlib entry installs nothing there. Returns `[]` when no lockfile resolves or its YAML is
      # unreadable. A pure YAML read, so the ADR-87 boot-slimming probe can rebuild the library list from it.
      def self.stdlib_library_names(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
        resolved = resolve_lockfile_path(lockfile_path: lockfile_path, project_root: project_root,
                                         auto_detect: auto_detect)
        return [] if resolved.nil?

        data = read_lockfile_yaml(resolved)
        return [] if data.nil?

        Array(data["gems"]).filter_map do |entry|
          next unless entry.is_a?(Hash) && SKIPPED_SOURCE_TYPES.include?(source_type(entry))

          name = entry["name"]
          name.to_s if name.is_a?(String) && !name.empty?
        end.uniq
      end

      # Issue #2971 — the `name` of every lockfile entry that is NOT a `stdlib` source and whose
      # `<root>/<name>/<version>/` directory exists: the gems whose signatures come from the collection ({.discover}).
      # The `libraries:` audit uses it so a name the collection provides is not reported as an unknown RBS library.
      # A pure file read, like {.stdlib_library_names}.
      def self.collection_gem_names(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
        resolved = resolve_lockfile_path(lockfile_path: lockfile_path, project_root: project_root,
                                         auto_detect: auto_detect)
        return [] if resolved.nil?

        data = read_lockfile_yaml(resolved)
        return [] if data.nil?

        collection_root = resolve_collection_root(resolved, data)
        gem_paths_from(collection_root, data, Set.new).map { |dir| dir.parent.basename.to_s }.uniq
      end

      # Issue #3030 — whether `file`, found under the collection gem directory `root`, sits below a `_`-prefixed
      # directory (`_test/`, `_scripts/`). Such a file is not part of the gem's signatures: rbs's
      # `EnvironmentLoader` loads a collection gem as a library, and `RBS::FileFinder.each_file(skip_hidden: true)`
      # drops every file with a `_`-prefixed directory between it and the library root. A `git` source never
      # copies them into the collection (`Sources::Git#cp_r` prunes them), but a `local` source symlinks the whole
      # `<name>/<version>/` directory, so gem_rbs_collection's own `bin/test` setup brings each gem's `_test/`
      # fixtures along. Only the directories count, as in rbs: a `_`-prefixed file name is loaded.
      def self.hidden_file?(root, file)
        relative = Pathname(file.to_s).relative_path_from(Pathname(root.to_s))
        relative.ascend.drop(1).any? { |part| part.basename.to_s.start_with?("_") }
      end

      # Issue #3030 — `collection_paths` ({.discover}) without each gem directory a `signature_paths:` root already
      # loads a copy of. A root is a copy of the entry `<collection>/<name>/<version>` when its real path is the
      # entry's real path (a `local` source symlinks the working tree in), or when it is a gem_rbs_collection working
      # tree for the same gem and version, `.../gems/<name>/<version>` (a `git` source installs a copy of it). That is
      # what an author editing the tree points `signature_paths:` at from its `_test/` directory while the lockfile
      # installs the same gem, and loading both declares every member twice. The `signature_paths:` copy is kept, as
      # it is the one being edited. Any other root, such as a partial override `sig/overrides/foo/1.0`, leaves the
      # collection copy loaded. Real paths are read so `..` and a symlinked spelling answer the same; a root that
      # does not exist matches nothing.
      def self.without_signature_path_copies(collection_paths, signature_roots)
        reals = signature_roots.filter_map { |root| real_path(root) }
        return collection_paths if reals.empty?

        trees = reals.filter_map do |real|
          real = Pathname(real)
          [real.parent.basename.to_s, real.basename.to_s] if real.parent.parent.basename.to_s == "gems"
        end.to_set
        reals = reals.to_set
        collection_paths.reject do |path|
          path = Pathname(path.to_s)
          trees.include?([path.parent.basename.to_s, path.basename.to_s]) || reals.include?(real_path(path))
        end
      end

      def self.real_path(path)
        File.realpath(path.to_s)
      rescue SystemCallError
        nil
      end
      private_class_method :real_path

      # Issue #3030 — why a run with no collection lockfile looks like it was meant to have one: `:collection_test_dir`
      # when `project_root` is a gem_rbs_collection test directory (`gems/<name>/<version>/_test/`, whose lockfile
      # gem_rbs_collection's `bin/test` setup writes), `:collection_config` when it holds an `rbs_collection.yaml`
      # (`rbs collection install` has not run), and nil otherwise, or when a lockfile resolves or the lookup is off.
      # Rigor resolves no `manifest.yaml` or gemspec dependency itself, so without the lockfile the dependency RBS
      # is absent. Two `stat`s and no read.
      def self.missing_lockfile_hint(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
        return nil if lockfile_path.nil? && !auto_detect
        return nil if resolve_lockfile_path(lockfile_path: lockfile_path, project_root: project_root,
                                            auto_detect: auto_detect)

        root = Pathname(File.expand_path(project_root.to_s))
        return :collection_test_dir if collection_test_dir?(root)
        return :collection_config if root.join("rbs_collection.yaml").file?

        nil
      end

      # `gems/<name>/<version>/_test/`, the layout of a gem_rbs_collection working tree.
      def self.collection_test_dir?(root)
        root.basename.to_s == "_test" && root.parent.parent.parent.basename.to_s == "gems"
      end
      private_class_method :collection_test_dir?

      # Returns the resolved lockfile path (`Pathname`) or `nil` when neither explicit nor auto-detect
      # produces one. Public so the stats banner can surface what rigor found.
      def self.resolve_lockfile_path(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
        if lockfile_path
          path = Pathname.new(configured_lockfile_path(lockfile_path, project_root))
          return path if path.file?

          return nil
        end

        return nil unless auto_detect

        candidate = Pathname.new(File.join(project_root, "rbs_collection.lock.yaml"))
        candidate.file? ? candidate : nil
      end

      def self.read_lockfile_yaml(path)
        data = YAML.safe_load_file(path.to_s, aliases: false)
        data.is_a?(Hash) ? data : nil
      rescue StandardError
        nil
      end
      private_class_method :read_lockfile_yaml

      def self.resolve_collection_root(lockfile_pathname, data)
        rel = data["path"]
        rel = DEFAULT_COLLECTION_PATH if rel.nil? || rel.to_s.empty?
        # `path:` is documented as relative to the directory holding the lockfile
        # (RBS::Collection::Config::Lockfile#fullpath).
        lockfile_pathname.parent + Pathname.new(rel.to_s)
      end
      private_class_method :resolve_collection_root

      # An entry's `source.type`, or "" when `source:` is absent or not a mapping (`source: stdlib`): a malformed
      # entry fails soft (ADR-5) instead of raising out of the run.
      def self.source_type(entry)
        source = entry["source"]
        source.is_a?(Hash) ? source["type"].to_s : ""
      end
      private_class_method :source_type

      def self.gem_paths_from(collection_root, data, skip_gem_names)
        Array(data["gems"]).filter_map do |entry|
          next unless entry.is_a?(Hash)

          next if SKIPPED_SOURCE_TYPES.include?(source_type(entry))

          name = entry["name"]
          version = entry["version"]
          next if name.nil? || version.nil?
          next if skip_gem_names.include?(name.to_s)

          gem_root = collection_root + name.to_s + version.to_s
          gem_root if gem_root.directory?
        end
      end
      private_class_method :gem_paths_from
    end
  end
end
