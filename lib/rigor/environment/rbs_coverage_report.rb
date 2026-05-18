# frozen_string_literal: true

module Rigor
  class Environment
    # Open item O4 Layer 3 slice 3 — graceful-degradation
    # coverage report.
    #
    # When the user has a `Gemfile.lock` (via slice 1) and rigor
    # has resolved its target-project RBS sources (DEFAULT_LIBRARIES,
    # `data/vendored_gem_sigs/`, slice-1 bundle-shipped `sig/`,
    # slice-2 `rbs_collection.lock.yaml` paths), this module
    # classifies each locked gem by RBS provenance and surfaces
    # the "no RBS available" set so the run-start diagnostic in
    # {Rigor::Analysis::Runner} can suggest `rbs collection
    # install` or `dependencies.source_inference:` for the
    # uncovered gems.
    #
    # The classification is a pure function over the inputs
    # (`locked_gems`, two arrays of resolved sig paths). It does
    # NOT touch the filesystem on its own — the caller passes in
    # what discovery returned.
    module RbsCoverageReport
      # Frozen result row.
      #
      # `source` is a Symbol naming where RBS for this gem
      # resolves; `:missing` means none of the four resolution
      # paths covered it.
      Coverage = Data.define(:gem_name, :version, :source) do
        def initialize(gem_name:, version:, source:)
          super(
            gem_name: -gem_name.to_s,
            version: -version.to_s,
            source: source
          )
        end
      end

      # Names of gems whose RBS ships under
      # `data/vendored_gem_sigs/`. Kept in sync with the
      # vendored-stubs directory listing; when a new gem is
      # vendored, add its name here too. (The set is small
      # enough that hard-coding is acceptable; a directory walk
      # at every call would add stat-cost to no benefit.)
      VENDORED_GEM_NAMES = Set[
        "bcrypt", "idn-ruby", "mysql2", "nokogiri", "pg", "prism", "redis"
      ].freeze

      # @param locked_gems [Hash{String => LockfileResolver::LockedGem}]
      #   The lockfile-resolved gem set. Empty hash → no
      #   coverage analysis to do.
      # @param default_libraries [Array<String>] gem names rigor
      #   auto-loads through `RBS::EnvironmentLoader#add(library:)`.
      #   Pass `Rigor::Environment::DEFAULT_LIBRARIES` from callers
      #   running in a project context.
      # @param bundle_sig_paths [Array<Pathname, String>] the
      #   discovered `<bundle>/.../gems/<name>-<ver>/sig` paths
      #   from {BundleSigDiscovery.discover}.
      # @param rbs_collection_paths [Array<Pathname, String>] the
      #   discovered `<collection>/<name>/<version>/` paths from
      #   {RbsCollectionDiscovery.discover}.
      # @return [Array<Coverage>] one row per locked gem; sorted
      #   by gem name for deterministic output.
      def self.classify(locked_gems:, default_libraries:,
                        bundle_sig_paths:, rbs_collection_paths:)
        default_set = default_libraries.to_set
        bundle_names = extract_gem_names_from_bundle_paths(bundle_sig_paths)
        collection_names = extract_gem_names_from_collection_paths(rbs_collection_paths)

        locked_gems.each_value.map do |locked|
          name = locked.name
          source = if default_set.include?(name)
                     :default_library
                   elsif VENDORED_GEM_NAMES.include?(name)
                     :vendored_gem_sig
                   elsif bundle_names.include?(name)
                     :bundle_sig
                   elsif collection_names.include?(name)
                     :rbs_collection
                   else
                     :missing
                   end
          Coverage.new(gem_name: name, version: locked.version, source: source)
        end.sort_by(&:gem_name)
      end

      # Convenience accessor for the run-start diagnostic.
      # Filters {classify} down to `:missing` rows.
      def self.missing(coverage_rows)
        coverage_rows.select { |row| row.source == :missing }
      end

      def self.extract_gem_names_from_bundle_paths(paths)
        paths.each_with_object(Set.new) do |path, set|
          pathname = path.is_a?(Pathname) ? path : Pathname.new(path)
          set << BundleSigDiscovery.gem_name_from_sig_path(pathname)
        end
      end
      private_class_method :extract_gem_names_from_bundle_paths

      def self.extract_gem_names_from_collection_paths(paths)
        # `RbsCollectionDiscovery.discover` returns
        # `<collection_root>/<name>/<version>/` so the parent
        # basename is the gem name.
        paths.each_with_object(Set.new) do |path, set|
          pathname = path.is_a?(Pathname) ? path : Pathname.new(path)
          set << pathname.parent.basename.to_s
        end
      end
      private_class_method :extract_gem_names_from_collection_paths
    end
  end
end
