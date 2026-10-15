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

      # `<bundle>/ruby/X.Y.Z/gems/<name>-<version>[-<platform>]/` — the same pure-filesystem layout
      # {MissingGemConstantIndex.bundle_gem_dirs} walks, preferred over the host's gems so a project that
      # vendored its bundle without committing the lockfile is read from its own tree. A platform-tagged
      # directory (`commonmarker-2.10.0-arm64-darwin`) is kept with its platform as a variant: those builds
      # ship the same `lib/<name>.rb` and top-level namespace as the `ruby` one, and the index looks the
      # directory up by that variant. A name installed more than once keeps every directory as a variant.
      def from_bundle_tree(bundle_path)
        return {} if bundle_path.nil?

        base = Pathname.new(bundle_path)
        return {} unless base.directory?

        Dir.glob(base.join("ruby", "*", "gems", "*")).each_with_object({}) do |dir, acc|
          name, version, platform = split_install_dirname(File.basename(dir))
          next unless name

          prior = acc[name]
          acc[name] = if prior
                        prior.with(variants: [*prior.variants, [version, platform]])
                      else
                        locked_gem(name, version, platform)
                      end
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

      def locked_gem(name, version, platform = "ruby")
        LockfileResolver::LockedGem.new(name: name, version: version, platform: platform)
      end

      # Splits a gem install directory's basename into `[name, version, platform]`, or nil. The version
      # always starts with a digit and carries no hyphen; a platform tail is accepted only when RubyGems
      # recognises its OS (`arm64-darwin`, `x86_64-linux-gnu`, `java`), so `foo-2fa-1.0` stays the plain gem
      # `foo-2fa`. The platform split is tried first, because a plain split of `foo-1.0-universal-darwin-23`
      # would claim the name `foo-1.0-universal-darwin`; and from the rightmost version-shaped segment,
      # because RubyGems also reads `1.0-x86_64-linux` as a linux platform, which would cut
      # `foo-2fa-1.0-x86_64-linux` at `foo`.
      def split_install_dirname(basename)
        platform_split(basename) || plain_split(basename)
      end

      def platform_split(basename)
        cuts = []
        basename.scan(/-(\d[^-]*)(?=-.)/) { cuts << Regexp.last_match }
        cuts.reverse_each do |match|
          platform = match.post_match.delete_prefix("-")
          # `current` makes `Gem::Platform.new` read the host's platform, which a non-main Ractor may not touch.
          next if platform == "current"
          return [match.pre_match, match[1], platform] unless Gem::Platform.new(platform).os == "unknown"
        end
        nil
      end

      def plain_split(basename)
        match = /\A(.+)-(\d[^-]*)\z/.match(basename)
        match ? [match[1], match[2], "ruby"] : nil
      end
    end
  end
end
