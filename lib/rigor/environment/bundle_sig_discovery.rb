# frozen_string_literal: true

require "yaml"

module Rigor
  class Environment
    # Target-project Bundler awareness (O4, implemented).
    #
    # Walks a Bundler-installed gem tree (e.g., the project's `vendor/bundle` or a Docker-mounted bundle
    # root) and returns the per-gem `sig/` directories to feed into `RbsLoader`'s `signature_paths:`. Of the
    # ~3% of gems that ship `sig/` in their gem package today (per the four-project Mastodon Docker
    # bundle-install measurement on 2026-05-15: 10 of 343 gems shipped sig — `prism`, `aws-sdk-s3`,
    # `aws-sdk-kms`, `aws-sdk-core`, `playwright-ruby-client`, `mutex_m`, `webrick`, `base64`, `stoplight`,
    # `ffi`), this discovery surfaces the typed contract the gem author explicitly published.
    #
    # Conflicts with rigor's bundled stdlib RBS (the prism case was the motivating example) degrade
    # gracefully via O7's failure-memo in `RbsLoader#env`: a single warning naming the offending file is
    # emitted and analysis continues with `Dynamic[top]` everywhere rather than hanging.
    #
    # The discovery is intentionally a pure file-system walk — no `Bundler` API call, no `Gemfile.lock`
    # parse — so rigor doesn't need the target project's Bundler context.
    module BundleSigDiscovery
      # Gems already covered by rigor's `DEFAULT_LIBRARIES` (stdlib RBS) plus the `data/vendored_gem_sigs/`
      # bundle. Skipping these from bundle discovery prevents `RBS::DuplicatedDeclarationError` (the prism
      # case was the motivating example — Ruby 4.0 ships prism's RBS in stdlib, and the gem also ships its
      # own `sig/`, so loading both raises on `Prism::BACKEND` etc.).
      #
      # The list is hard-coded for the MVP because it tracks rigor's bundled coverage 1:1. When a new gem is
      # vendored under `data/vendored_gem_sigs/` or added to `DEFAULT_LIBRARIES`, add its name here.
      SKIPPED_GEMS_BY_DEFAULT = Set[
        # DEFAULT_LIBRARIES (lib/rigor/environment.rb)
        "pathname", "optparse", "json", "yaml", "fileutils",
        "tempfile", "tmpdir", "stringio", "forwardable",
        "digest", "securerandom", "uri", "logger", "date",
        "pp", "delegate", "singleton", "observable", "abbrev",
        "find", "tsort", "shellwords", "benchmark", "base64",
        "did_you_mean", "monitor", "mutex_m", "timeout",
        "open3", "erb", "etc", "ipaddr", "bigdecimal",
        "bigdecimal-math", "prettyprint",
        "random-formatter", "time", "open-uri", "resolv",
        "csv", "pstore", "objspace", "io-console", "cgi", "cgi-escape",
        "strscan",
        "prism", "rbs",
        # data/vendored_gem_sigs/
        "pg", "mysql2", "nokogiri", "bcrypt", "redis", "idn-ruby", "racc",
        "bundler", "rubygems"
      ].freeze

      # @param bundle_path [String, Pathname, nil] explicit path to the bundler install root. When `nil`,
      #   falls back to `auto_detect` if `auto_detect:` is true.
      # @param project_root [String] resolution base for relative `bundle_path:` and the auto-detect search.
      # @param auto_detect [Boolean] when true and `bundle_path:` is nil, try `.bundle/config`'s
      #   `BUNDLE_PATH:` and `vendor/bundle/` under `project_root`.
      # @param skip_gems [Set<String>] gem names to exclude from discovery. Defaults to
      #   {SKIPPED_GEMS_BY_DEFAULT}.
      # @param locked_gems [Hash{String => LockfileResolver::LockedGem}, nil] Optional O4-Layer-3 filter.
      #   When non-nil and non-empty, only `sig/` directories whose gem `(name, version, platform)` tuple
      #   matches a lockfile entry are returned. Bundle entries absent from the lockfile (or at a drifted
      #   version) are silently dropped — the lockfile is treated as the source of truth for "what gems this
      #   project actually declares". A git-sourced directory carries no version to compare (see
      #   {.gem_name_from_sig_path}), so for those the filter instead requires the matching `locked_gems`
      #   entry to have `git_source: true` — name alone is not enough, since a gem that moved off a `git:`
      #   source keeps its stale `bundler/gems/` directory under the SAME name until a `bundle clean`. Pass
      #   `nil` (the default) to keep the pre-Layer-3 behaviour of returning every non-skipped `sig/` under
      #   the bundle.
      # @return [Array<Pathname>] every `<gem-dir>/sig` directory under the resolved bundle path, minus any
      #   whose gem name is in `skip_gems` and (when `locked_gems` is supplied) minus any whose `(name,
      #   version, platform)` does not match a lockfile entry.
      def self.discover(bundle_path:, project_root: Dir.pwd, auto_detect: true,
                        skip_gems: SKIPPED_GEMS_BY_DEFAULT, locked_gems: nil, home: nil)
        resolved = resolve_bundle_path(
          bundle_path: bundle_path,
          project_root: project_root,
          auto_detect: auto_detect,
          home: home
        )
        return [] if resolved.nil?

        # Two bundler-install layouts, both under the same `ruby/X.Y.Z/` root (`*` picks up whichever Ruby
        # the bundle was installed for):
        #
        # - `gems/<name>-<ver>/sig/` — the RubyGems-sourced layout, the canonical case.
        # - `bundler/gems/<repo>-<12-hex-revision>/sig/` — `git:`-sourced gems (`Bundler::Source::Git#
        #   install_path`); the directory name carries the git repository's basename and a 12-character
        #   revision prefix, not the gem name or version. Before this, a fork's own `sig/` was invisible to
        #   rigor no matter how it was authored — see issue #611.
        #
        # `path:`-sourced gems are NOT under either glob: Bundler does not copy them into the bundle root at
        # all (`Bundler::Source::Path#path` is the user's own `path:` directory, used in place), so there is
        # no bundle-relative location to walk. A `path:`-sourced gem's `sig/` is only reachable by adding it
        # directly to the project's `signature_paths:` — which already works today and needs no discovery.
        all = (Dir.glob(resolved.join("ruby", "*", "gems", "*", "sig")) +
               Dir.glob(resolved.join("ruby", "*", "bundler", "gems", "*", "sig"))).map { |d| Pathname.new(d) }
        filtered = all.reject { |sig_dir| skip_gems.include?(gem_name_from_sig_path(sig_dir)) }
        return filtered if locked_gems.nil? || locked_gems.empty?

        expected_dirs = expected_gem_dirs(locked_gems)
        filtered.select do |sig_dir|
          if git_sourced_layout?(sig_dir)
            # A git install's directory name carries no resolvable version (see above), so the lockfile
            # filter can only check the gem NAME, not `(name, version)` — but name alone is not enough: a
            # gem that used to be `git:`-sourced and has since moved to a released version keeps its old
            # `bundler/gems/<repo>-<sha>/` directory sitting in the bundle tree until a `bundle clean`, and
            # its NAME is still present in the lockfile (now via the rubygems entry). Matching on name only
            # would silently readmit that stale git install — this repo's own `vendor/bundle` had exactly
            # this after `binpacker` moved from `git:` to a released gem. `locked_gems` must say this name is
            # CURRENTLY git-sourced, not merely present.
            locked = locked_gems[gem_name_from_sig_path(sig_dir)]
            !!locked&.git_source
          else
            expected_dirs.include?(sig_dir.parent.basename.to_s)
          end
        end
      end

      # `{name => LockedGem}` → set of canonical bundler gem directory basenames. Pure-Ruby gems install as
      # `<name>-<version>`; platform-specific gems install as `<name>-<version>-<platform>` (e.g.
      # `ffi-1.17.4-aarch64-linux-gnu`). Lockfile platform `"ruby"` is the pure-Ruby case; any other value is
      # treated as a platform tag.
      def self.expected_gem_dirs(locked_gems)
        locked_gems.each_value.with_object(Set.new) do |locked, set|
          base = "#{locked.name}-#{locked.version}"
          set << if locked.platform == "ruby" || locked.platform.empty?
                   base
                 else
                   "#{base}-#{locked.platform}"
                 end
        end
      end
      private_class_method :expected_gem_dirs

      # `<bundle>/ruby/X.Y.Z/gems/<name>-<ver>/sig` → `<name>`, or
      # `<bundle>/ruby/X.Y.Z/bundler/gems/<repo>-<12-hex-revision>/sig` → `<repo>`. The two bundler-install
      # layouts name their gem directory differently, so which suffix to strip depends on which layout
      # `sig_dir` came from:
      #
      # - rubygems layout: `<name>-<version>` (platform-tagged variants like `ffi-1.17.4-aarch64-linux-gnu/`
      #   keep their platform suffix in the version part) — the version always starts with a digit, so strip
      #   from the first `-` followed by a digit.
      # - git layout: `<repo-basename>-<12-hex-char-revision>` (`Bundler::Source::Git#install_path`) — no
      #   version at all, and the repository name need not equal the gem name (a fork hosted under a
      #   different repo name, a monorepo). Strip the fixed-width hex suffix instead; best-effort only, since
      #   the true gem name isn't recoverable from the filesystem without running Bundler.
      #
      # Public so the O4 Layer 3 slice-3 coverage report (`RbsCoverageReport`) can classify discovered bundle
      # sigs against locked gem names without re-running discovery.
      def self.gem_name_from_sig_path(sig_dir)
        gem_dir = sig_dir.parent.basename.to_s
        if git_sourced_layout?(sig_dir)
          gem_dir.sub(/-[0-9a-f]{12}\z/, "")
        else
          gem_dir.sub(/-\d.*\z/, "")
        end
      end

      # True when `sig_dir` sits under the `bundler/gems/` (git-sourced) layout rather than the plain
      # `gems/` (rubygems-sourced) layout — `<bundle>/ruby/X.Y.Z/bundler/gems/<dir>/sig` vs.
      # `<bundle>/ruby/X.Y.Z/gems/<dir>/sig`. A directory-shape check, not a name-shape guess: the two glob
      # roots in {.discover} are already disjoint, so this just recovers which one a given path came from.
      def self.git_sourced_layout?(sig_dir)
        gem_dir = sig_dir.parent
        gem_dir.parent.basename.to_s == "gems" && gem_dir.parent.parent.basename.to_s == "bundler"
      end
      private_class_method :git_sourced_layout?

      # Returns `Pathname` resolved bundle path, or `nil` when neither explicit nor auto-detected. Public
      # for the stats banner so end users can see what rigor picked up.
      def self.resolve_bundle_path(bundle_path:, project_root: Dir.pwd, auto_detect: true, home: nil)
        if bundle_path
          path = Pathname.new(File.expand_path(bundle_path.to_s, project_root))
          return path if path.directory?

          return nil
        end

        return nil unless auto_detect

        detected = auto_detect(project_root: project_root, home: home)
        Pathname.new(detected) if detected
      end

      # Auto-detection order — project-local strategies win over the user-global one, mirroring Bundler's own
      # config precedence:
      # 1. `<project_root>/.bundle/config` carries `BUNDLE_PATH:` set by `bundle config set --local path
      #    <dir>`.
      # 2. `<project_root>/vendor/bundle/` — the conventional in-tree install location when a developer ran
      #    `bundle install --path vendor/bundle`.
      # 3. The user-global bundler config `<home>/.bundle/config` `BUNDLE_PATH:` (`bundle config set
      #    --global path <dir>`), resolved relative to the project root and used only when it points at an
      #    existing directory — the last resort for a project with no in-tree bundle. Purely additive: it is
      #    consulted only when steps 1–2 found nothing, so it never changes an already-working detection.
      # 4. `nil` — let the caller proceed without bundle sig discovery (rigor's vendored RBS still loads).
      #
      # Note (ADR-27): rigor reads the *project* as data, so detection is limited to paths recorded in
      # project-local or user-global Bundler config files. The pure-default install location — gems in the
      # active Ruby's GEM_HOME with no `path` configured — is the *project's* Ruby's gem home, which the
      # isolated analyzer cannot know without running the project's toolchain. Point rigor at it with
      # `bundler.bundle_path:`, or supply signatures via `rbs collection install` /
      # `dependencies.source_inference:`. `BUNDLE_PATH` from rigor's own environment is deliberately NOT
      # consulted — it describes rigor's bundle, not the analyzed project's.
      #
      # `home:` defaults to the invoking user's home directory; it is a parameter so tests stay hermetic (no
      # read of the real `~/.bundle/config`).
      def self.auto_detect(project_root:, home: nil)
        from_config = read_bundle_config_path(File.join(project_root, ".bundle", "config"))
        return File.expand_path(from_config, project_root) if from_config

        vendor = File.join(project_root, "vendor", "bundle")
        return vendor if File.directory?(vendor)

        global_bundle_path(project_root: project_root, home: home)
      end

      # Resolves the user-global `BUNDLE_PATH` against the project root, returning it only when it is an
      # existing directory. Returns nil when there is no global config, no home, or the configured path does
      # not exist.
      def self.global_bundle_path(project_root:, home:)
        home ||= default_home
        return nil if home.nil?

        configured = read_bundle_config_path(File.join(home, ".bundle", "config"))
        return nil unless configured

        resolved = File.expand_path(configured, project_root)
        File.directory?(resolved) ? resolved : nil
      end
      private_class_method :global_bundle_path

      def self.default_home
        Dir.home
      rescue StandardError
        nil
      end
      private_class_method :default_home

      def self.read_bundle_config_path(config_path)
        return nil unless config_path && File.exist?(config_path)

        # `.bundle/config` is YAML with all-caps env-style keys. `BUNDLE_PATH:` is the canonical key
        # (Bundler 2.x); the `--path` flag sets it.
        data = YAML.safe_load_file(config_path)
        return nil unless data.is_a?(Hash)

        path = data["BUNDLE_PATH"]
        path && !path.to_s.empty? ? path.to_s : nil
      rescue StandardError
        # Malformed `.bundle/config` should not break analysis; silently skip auto-detection.
        nil
      end

      private_class_method :read_bundle_config_path
    end
  end
end
