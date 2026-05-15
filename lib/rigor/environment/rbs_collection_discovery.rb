# frozen_string_literal: true

require "yaml"

module Rigor
  class Environment
    # Open item O4 Layer 3 slice 2 — `rbs collection install`
    # awareness.
    #
    # When the target project has been set up with `rbs
    # collection install` (the standard RBS-ecosystem flow for
    # pulling community RBS from
    # https://github.com/ruby/gem_rbs_collection), a
    # `rbs_collection.lock.yaml` records the resolved (gem,
    # version, source) triples and `.gem_rbs_collection/<name>/
    # <version>/` carries the actual `.rbs` files. This module
    # parses the lockfile and returns the per-gem RBS directory
    # paths so they can be appended to `RbsLoader`'s
    # `signature_paths:`.
    #
    # The discovery is intentionally a pure file-system + YAML
    # walk — no Bundler API call, no network access. Failure
    # modes (missing lockfile, malformed YAML, missing
    # collection directory) silently degrade to an empty list.
    module RbsCollectionDiscovery
      # `stdlib`-typed entries in the lockfile are loaded into
      # the RBS environment by the standard library mechanism
      # (rigor's `Environment::DEFAULT_LIBRARIES` already covers
      # this surface). Including them as `signature_paths:`
      # entries would risk `RBS::DuplicatedDeclarationError`
      # (the same hazard O7's failure-memo handles). The other
      # documented source types — `git` (the gem_rbs_collection
      # repo), `rubygems` (sigs lifted from a gem's bundled
      # `sig/`), and `local` (a user-managed RBS dir) — all
      # produce a directory under the collection root and are
      # admitted.
      SKIPPED_SOURCE_TYPES = Set["stdlib"].freeze

      DEFAULT_COLLECTION_PATH = ".gem_rbs_collection"
      private_constant :DEFAULT_COLLECTION_PATH

      # @param lockfile_path [String, Pathname, nil] explicit
      #   path to `rbs_collection.lock.yaml`. When `nil`, falls
      #   back to `auto_detect` if `auto_detect:` is true.
      # @param project_root [String] resolution base for
      #   relative `lockfile_path:` and the auto-detect search.
      # @param auto_detect [Boolean] when true and
      #   `lockfile_path:` is nil, look for
      #   `<project_root>/rbs_collection.lock.yaml`.
      # @return [Array<Pathname>] every
      #   `<collection_path>/<gem-name>/<gem-version>/`
      #   directory listed in the lockfile whose entry has a
      #   non-skipped source type and whose directory exists on
      #   disk. Returns `[]` when no lockfile is resolvable,
      #   when the YAML is unreadable, or when the collection
      #   path doesn't exist.
      def self.discover(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
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

        gem_paths_from(collection_root, data)
      end

      # Returns the resolved lockfile path (`Pathname`) or `nil`
      # when neither explicit nor auto-detect produces one.
      # Public so the stats banner can surface what rigor found.
      def self.resolve_lockfile_path(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
        if lockfile_path
          path = Pathname.new(File.expand_path(lockfile_path.to_s, project_root))
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
        # `path:` is documented as relative to the directory
        # holding the lockfile (RBS::Collection::Config::Lockfile#fullpath).
        lockfile_pathname.parent + Pathname.new(rel.to_s)
      end
      private_class_method :resolve_collection_root

      def self.gem_paths_from(collection_root, data)
        Array(data["gems"]).filter_map do |entry|
          next unless entry.is_a?(Hash)

          source_type = entry.dig("source", "type").to_s
          next if SKIPPED_SOURCE_TYPES.include?(source_type)

          name = entry["name"]
          version = entry["version"]
          next if name.nil? || version.nil?

          gem_root = collection_root + name.to_s + version.to_s
          gem_root if gem_root.directory?
        end
      end
      private_class_method :gem_paths_from
    end
  end
end
