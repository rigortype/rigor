# frozen_string_literal: true

require "prism"

module Rigor
  class Environment
    # ADR-82 WD9 — maps a top-level constant name to the locked, RBS-less gem that declares it, so an
    # unresolved constant read (`Faraday`, `Sidekiq`) can carry the `external_gem_without_rbs` provenance
    # cause instead of the generic `unsupported_syntax`. For a gem with no RBS the constant read is where the
    # class name is last visible — by dispatch time the receiver is already `Dynamic[top]` — so this index is
    # what lets `coverage --protection` route those holes to `add_rbs` honestly.
    #
    # Ownership is established by READING, never by guessing: each gem's conventional entry file
    # (`lib/<name>.rb`, with the dash → directory variant) is parsed with Prism and its top-level
    # class / module / constant declarations recorded under their root name. No gem code runs — the same
    # posture as ADR-72's "loads RBS data only" and the ADR-10 walker. A name-derivation heuristic
    # (`faraday` → `Faraday` by camelizing) is deliberately NOT used: it breaks on irregular names
    # (`activesupport` → `ActiveSupport`) and is exactly the guessing the ADR-82 honesty criterion forbids.
    #
    # Everything fails OPEN to "no owner": a gem that is not installed, an entry file that does not exist or
    # does not parse, a root constant declared only in a deeper file. An unindexed constant keeps today's
    # generic cause — the failure mode is a missing label, never a wrong one.
    #
    # The scan is bounded to entry files (one or two per gem) so building the index over a real app's
    # hundreds of RBS-less gems stays sub-second; it is built lazily on the first unresolved constant, so a
    # project whose constants all resolve never pays it.
    #
    # **Gem-directory resolution.** Rigor runs under its OWN bundle (`BUNDLE_GEMFILE=<rigor>/Gemfile`), so
    # `Gem::Specification.find_by_name` sees rigor's gems, not the target project's — it would resolve only
    # the handful of gems both bundles happen to share (i18n, rack) and miss every project-specific gem
    # (the very ones a Rails app's holes root at). So the primary resolver is the **target's bundle install
    # tree** (`<bundle>/ruby/*/gems/<name>-<version>/`, the same pure-filesystem layout
    # {BundleSigDiscovery} walks — no `Bundler` API, no gem code). `Gem::Specification` remains a last-resort
    # fallback for a project installed against system gems with no discoverable bundle; reading a gem's own
    # entry file for its own top-level namespace constant is version-stable, so even a rigor-vs-target
    # version skew on a shared gem yields the same constant name.
    module MissingGemConstantIndex
      module_function

      # @rbs gems: Enumerable[[String, String]] --
      #   `[gem_name, version]` pairs (the `:missing` rows of {RbsCoverageReport}).
      # @rbs bundle_path: (String | Pathname)? -- The target's resolved bundler install root, or nil.
      # @rbs spec_resolver: untyped --
      #   `(name, version) -> String?` fallback dir resolver. Injectable for specs; the default is the
      #   RubyGems-metadata lookup (no code load).
      # @rbs return: Hash[String, String] --
      #   Frozen `root constant name => gem name`. On a collision (two gems declaring the same top-level constant) the
      #   first gem wins — the CAUSE recorded downstream (external gem without RBS) is true under either owner.
      def build(gems, bundle_path: nil, spec_resolver: method(:installed_gem_dir))
        bundle_dirs = bundle_gem_dirs(bundle_path)
        git_dirs = git_gem_dirs(bundle_path)
        index = {}
        gems.each do |gem_name, version|
          dir = bundle_dirs["#{gem_name}-#{version}"] || git_dirs[gem_name] || spec_resolver.call(gem_name, version)
          next unless dir

          entry_files(dir, gem_name).each do |file|
            top_level_root_constants(file).each { |name| index[name] ||= gem_name }
          end
        end
        index.freeze
      end

      # `{"<name>-<version>" => gem_dir}` for the target's bundle, or `{}` when no bundle is resolvable. The
      # glob covers the RUBYGEMS-sourced layout only, `<bundle>/ruby/X.Y.Z/gems/<name>-<version>/`; the
      # git-sourced layout is {.git_gem_dirs}'s. Keyed on the dir basename so a platform-tagged variant
      # (`ffi-1.17.4-aarch64-linux-gnu`) simply doesn't match a `<name>-<version>` lookup — those gems ship
      # native code, not the pure-Ruby constants this indexes.
      def bundle_gem_dirs(bundle_path)
        return {} if bundle_path.nil?

        base = Pathname.new(bundle_path)
        return {} unless base.directory?

        Dir.glob(base.join("ruby", "*", "gems", "*")).each_with_object({}) do |dir, acc|
          acc[File.basename(dir)] ||= dir
        end
      end

      # Issue #763 — `{gem_name => gem_dir}` for the target's GIT-sourced gems,
      # `<bundle>/ruby/X.Y.Z/bundler/gems/<repo>-<12-hex-revision>/`. Before this, a `git:`-sourced gem was
      # invisible to the index, so every constant reaching into it recorded the generic engine-gap cause
      # where the honest story is add-RBS — the same mislabelling #530 measures from two other directions.
      #
      # Keyed on the name read from the directory's `*.gemspec` FILENAME, not on the directory basename: a
      # git install's directory carries the repository name, which need not equal the gem name (a fork
      # hosted under a different repo name, a gem inside a monorepo). No gem code is loaded — this is the
      # filename, not an evaluated gemspec. A directory with no gemspec, or more than one, contributes
      # nothing rather than a guess.
      #
      # Deliberately NOT gated on the lockfile's `git_source` the way {BundleSigDiscovery} is, and the
      # difference is worth stating because the two look like the same problem. There, a stale
      # `bundler/gems/` directory left behind by a gem that moved to a released version made the loader
      # load the WRONG SIGNATURES, collapsing the RBS environment. Here the index's whole output is a gem
      # NAME, so reading a stale checkout of the same gem yields the same answer; and the rubygems lookup
      # is consulted FIRST in {.build}, so a gem now installed from RubyGems never reaches this map at all.
      def git_gem_dirs(bundle_path)
        return {} if bundle_path.nil?

        base = Pathname.new(bundle_path)
        return {} unless base.directory?

        Dir.glob(base.join("ruby", "*", "bundler", "gems", "*")).each_with_object({}) do |dir, acc|
          name = gemspec_gem_name(dir)
          acc[name] ||= dir if name
        end
      end

      # The gem name a checkout declares, from the single `*.gemspec` at its root, or nil when there is not
      # exactly one. Bundler requires a git-sourced gem to ship one, so "not exactly one" means this is not
      # the shape we think it is — and a guess from the directory basename is what this exists to avoid.
      def gemspec_gem_name(dir)
        specs = Dir.glob(File.join(dir, "*.gemspec"))
        return nil unless specs.size == 1

        File.basename(specs.first, ".gemspec")
      end

      # RubyGems spec metadata lookup — the gem's on-disk source root, without loading any of its code.
      # Exact-version first, any-version fallback. See the class note on why this is only a fallback.
      def installed_gem_dir(name, version)
        spec = begin
          Gem::Specification.find_by_name(name, "= #{version}")
        rescue Gem::LoadError
          begin
            Gem::Specification.find_by_name(name)
          rescue Gem::LoadError
            nil
          end
        end
        spec&.full_gem_path
      end

      # The conventional require targets for a gem name: `lib/foo.rb`, and `lib/foo/bar.rb` for a dashed
      # `foo-bar`. This is the require-name convention Bundler.require depends on — a filename convention,
      # not a constant-name guess; the constants come from parsing whichever of these exists.
      def entry_files(dir, gem_name)
        candidates = ["lib/#{gem_name}.rb"]
        candidates << "lib/#{gem_name.tr('-', '/')}.rb" if gem_name.include?("-")
        candidates.filter_map do |relative|
          path = File.join(dir, relative)
          path if File.file?(path)
        end
      end

      # Root names of the file's top-level declarations. Only direct children of the program are read — the
      # root constant of a gem's namespace is declared at file top level by construction (`module Faraday`,
      # `class Money::Error < …` roots at `Money`), so no recursion into bodies is needed.
      def top_level_root_constants(path)
        result = Prism.parse(File.read(path))
        return [] unless result.errors.empty?

        result.value.statements.body.filter_map do |node|
          case node
          when Prism::ClassNode, Prism::ModuleNode then root_segment(node.constant_path)
          when Prism::ConstantWriteNode then node.name.to_s
          end
        end
      rescue StandardError
        []
      end

      def root_segment(node)
        current = node
        current = current.parent while current.is_a?(Prism::ConstantPathNode) && current.parent
        current.respond_to?(:name) && current.name ? current.name.to_s : nil
      end
    end
  end
end
