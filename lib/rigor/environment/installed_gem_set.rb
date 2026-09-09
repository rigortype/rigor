# frozen_string_literal: true

require_relative "lockfile_resolver"

module Rigor
  class Environment
    # Issue #530 — the gem set for a project that has NO `Gemfile.lock`.
    #
    # ADR-82 WD9's constant-ownership index is driven by the LOCKED gem set, so a project without a
    # lockfile (a plain library, a `gemspec`-only gem, an app vendored outside Bundler) handed the index
    # nothing at all: every constant reaching into a real, installed, RBS-less gem recorded the generic
    # cause, and the entire gem boundary reported as `engine_gap` — "report this to Rigor" — where the
    # honest story is `add_rbs`. Measured on slim, whose whole Temple boundary lands that way while haml,
    # which has a lockfile, attributes the same gem correctly.
    #
    # Degrading to the gems that are actually INSTALLED keeps ADR-82's honesty criterion intact. A name
    # here is a gem that exists on disk; the index still has to READ its entry file before claiming any
    # constant, and its lack of RBS is established by the same {RbsCoverageReport.classify} pass the
    # lock-driven path uses. The version is the one on disk rather than a declared one — which is the
    # version a lockfile-less project would load anyway.
    #
    # Only the missing-gem provenance index consumes this. The ADR-72 gem overlays stay Gemfile.lock-gated:
    # an overlay changes what type-checks, so it needs the project's own declaration, while this
    # side-channel only changes a label.
    module InstalledGemSet
      module_function

      # @param bundle_path — the target's resolved bundler install root, or nil.
      # @return frozen `gem name => LockfileResolver::LockedGem`, the shape
      #   {RbsCoverageReport.classify} consumes. Empty when neither resolver sees anything, which leaves
      #   today's generic cause in place.
      def gems(bundle_path: nil)
        found = from_bundle_tree(bundle_path)
        found = from_installed_specs if found.empty?
        found.freeze
      end

      # `<bundle>/ruby/X.Y.Z/gems/<name>-<version>/` — the same pure-filesystem layout
      # {MissingGemConstantIndex.bundle_gem_dirs} walks, preferred over the host's gems so a project that
      # vendored its bundle without committing the lockfile is read from its own tree. A platform-tagged
      # directory (`ffi-1.17.4-aarch64-linux-gnu`) does not split into a name/version pair and is skipped:
      # those gems ship native code, not the pure-Ruby constants this feeds.
      def from_bundle_tree(bundle_path)
        return {} if bundle_path.nil?

        base = Pathname.new(bundle_path)
        return {} unless base.directory?

        Dir.glob(base.join("ruby", "*", "gems", "*")).each_with_object({}) do |dir, acc|
          name, version = split_name_version(File.basename(dir))
          next unless name

          acc[name] ||= locked_gem(name, version)
        end
      end

      # The gems the RUNNING Ruby can load. For the shipped `gem install rigortype` distribution that IS a
      # lockfile-less project's gem environment — the same set its own `require` would reach. Under
      # `bundle exec` it is the analyzer's own bundle instead (the `Gem.paths`-no-ops-under-Bundler
      # mechanism ADR-90 documents), which yields fewer names, never wrong ones. Highest version per name,
      # because `stubs` promises no ordering.
      def from_installed_specs
        Gem::Specification.stubs.each_with_object({}) do |stub, acc|
          previous = acc[stub.name]
          next if previous && Gem::Version.new(previous.version) >= stub.version

          acc[stub.name] = locked_gem(stub.name, stub.version.to_s)
        end
      rescue StandardError
        {}
      end

      def locked_gem(name, version)
        LockfileResolver::LockedGem.new(name: name, version: version, platform: "ruby")
      end

      # Splits a gem install directory's basename. The version tail is anchored on a leading digit and must
      # carry no further hyphen, which is what excludes the platform-tagged variants above.
      def split_name_version(basename)
        match = /\A(.+)-(\d[^-]*)\z/.match(basename)
        match ? [match[1], match[2]] : nil
      end
    end
  end
end
