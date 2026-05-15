# frozen_string_literal: true

require "yaml"

module Rigor
  class Environment
    # Open item O4 — target-project Bundler awareness.
    #
    # Walks a Bundler-installed gem tree (e.g., the project's
    # `vendor/bundle` or a Docker-mounted bundle root) and
    # returns the per-gem `sig/` directories to feed into
    # `RbsLoader`'s `signature_paths:`. Of the ~3% of gems that
    # ship `sig/` in their gem package today (per the four-project
    # Mastodon Docker bundle-install measurement on 2026-05-15:
    # 10 of 343 gems shipped sig — `prism`, `aws-sdk-s3`,
    # `aws-sdk-kms`, `aws-sdk-core`, `playwright-ruby-client`,
    # `mutex_m`, `webrick`, `base64`, `stoplight`, `ffi`), this
    # discovery surfaces the typed contract the gem author
    # explicitly published.
    #
    # Conflicts with rigor's bundled stdlib RBS (the prism case
    # was the motivating example) degrade gracefully via O7's
    # failure-memo in `RbsLoader#env`: a single warning naming
    # the offending file is emitted and analysis continues with
    # `Dynamic[top]` everywhere rather than hanging.
    #
    # The discovery is intentionally a pure file-system walk —
    # no `Bundler` API call, no `Gemfile.lock` parse — so rigor
    # doesn't need the target project's Bundler context.
    module BundleSigDiscovery
      # Gems already covered by rigor's `DEFAULT_LIBRARIES`
      # (stdlib RBS) plus the `data/vendored_gem_sigs/` bundle.
      # Skipping these from bundle discovery prevents
      # `RBS::DuplicatedDeclarationError` (the prism case was the
      # motivating example — Ruby 4.0 ships prism's RBS in
      # stdlib, and the gem also ships its own `sig/`, so loading
      # both raises on `Prism::BACKEND` etc.).
      #
      # The list is hard-coded for the MVP because it tracks
      # rigor's bundled coverage 1:1. When a new gem is vendored
      # under `data/vendored_gem_sigs/` or added to
      # `DEFAULT_LIBRARIES`, add its name here.
      SKIPPED_GEMS_BY_DEFAULT = Set[
        # DEFAULT_LIBRARIES (lib/rigor/environment.rb)
        "pathname", "optparse", "json", "yaml", "fileutils",
        "tempfile", "tmpdir", "stringio", "forwardable",
        "digest", "securerandom", "uri", "logger", "date",
        "pp", "delegate", "observable", "abbrev",
        "find", "tsort", "shellwords", "benchmark", "base64",
        "did_you_mean", "monitor", "mutex_m", "timeout",
        "open3", "erb", "etc", "ipaddr", "bigdecimal",
        "prism", "rbs",
        # data/vendored_gem_sigs/
        "pg", "mysql2", "nokogiri", "bcrypt", "redis", "idn-ruby"
      ].freeze

      # @param bundle_path [String, Pathname, nil] explicit path
      #   to the bundler install root. When `nil`, falls back to
      #   `auto_detect` if `auto_detect:` is true.
      # @param project_root [String] resolution base for relative
      #   `bundle_path:` and the auto-detect search.
      # @param auto_detect [Boolean] when true and `bundle_path:`
      #   is nil, try `.bundle/config`'s `BUNDLE_PATH:` and
      #   `vendor/bundle/` under `project_root`.
      # @param skip_gems [Set<String>] gem names to exclude from
      #   discovery. Defaults to {SKIPPED_GEMS_BY_DEFAULT}.
      # @param locked_gems [Hash{String => LockfileResolver::LockedGem}, nil]
      #   Optional O4-Layer-3 filter. When non-nil and non-empty,
      #   only `sig/` directories whose gem `(name, version,
      #   platform)` tuple matches a lockfile entry are returned.
      #   Bundle entries absent from the lockfile (or at a drifted
      #   version) are silently dropped — the lockfile is treated
      #   as the source of truth for "what gems this project
      #   actually declares". Pass `nil` (the default) to keep
      #   the pre-Layer-3 behaviour of returning every non-skipped
      #   `sig/` under the bundle.
      # @return [Array<Pathname>] every `<gem-dir>/sig` directory
      #   under the resolved bundle path, minus any whose gem
      #   name is in `skip_gems` and (when `locked_gems` is
      #   supplied) minus any whose `(name, version, platform)`
      #   does not match a lockfile entry.
      def self.discover(bundle_path:, project_root: Dir.pwd, auto_detect: true,
                        skip_gems: SKIPPED_GEMS_BY_DEFAULT, locked_gems: nil)
        resolved = resolve_bundle_path(
          bundle_path: bundle_path,
          project_root: project_root,
          auto_detect: auto_detect
        )
        return [] if resolved.nil?

        # `<bundle>/ruby/X.Y.Z/gems/<name>-<ver>/sig/` is the
        # canonical bundler layout. `*` on the ruby version dir
        # picks up whichever Ruby the bundle was installed for.
        all = Dir.glob(resolved.join("ruby", "*", "gems", "*", "sig")).map { |d| Pathname.new(d) }
        filtered = all.reject { |sig_dir| skip_gems.include?(gem_name_from_sig_path(sig_dir)) }
        return filtered if locked_gems.nil? || locked_gems.empty?

        expected_dirs = expected_gem_dirs(locked_gems)
        filtered.select { |sig_dir| expected_dirs.include?(sig_dir.parent.basename.to_s) }
      end

      # `{name => LockedGem}` → set of canonical bundler gem
      # directory basenames. Pure-Ruby gems install as
      # `<name>-<version>`; platform-specific gems install as
      # `<name>-<version>-<platform>` (e.g. `ffi-1.17.4-aarch64-linux-gnu`).
      # Lockfile platform `"ruby"` is the pure-Ruby case; any
      # other value is treated as a platform tag.
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

      # `<bundle>/ruby/X.Y.Z/gems/<name>-<ver>/sig` → `<name>`.
      # The gem directory follows the canonical
      # `<name>-<version>` pattern; we strip everything from the
      # last hyphen onwards to recover the name. (Platform-tagged
      # variants like `ffi-1.17.4-aarch64-linux-gnu/` keep their
      # platform suffix in the version part, so the first hyphen
      # from the right is still the name boundary.)
      def self.gem_name_from_sig_path(sig_dir)
        gem_dir = sig_dir.parent.basename.to_s
        # Strip `-<version>` and any platform suffix. The version
        # always starts with a digit, so split at the first
        # `-` followed by a digit.
        gem_dir.sub(/-\d.*\z/, "")
      end
      private_class_method :gem_name_from_sig_path

      # Returns `Pathname` resolved bundle path, or `nil` when
      # neither explicit nor auto-detected. Public for the stats
      # banner so end users can see what rigor picked up.
      def self.resolve_bundle_path(bundle_path:, project_root: Dir.pwd, auto_detect: true)
        if bundle_path
          path = Pathname.new(File.expand_path(bundle_path.to_s, project_root))
          return path if path.directory?

          return nil
        end

        return nil unless auto_detect

        detected = auto_detect(project_root: project_root)
        Pathname.new(detected) if detected
      end

      # Auto-detection order:
      # 1. `<project_root>/.bundle/config` carries `BUNDLE_PATH:`
      #    set by `bundle config set --local path <dir>`.
      # 2. `<project_root>/vendor/bundle/` — the conventional
      #    in-tree install location when a developer ran
      #    `bundle install --path vendor/bundle`.
      # 3. `nil` — let the caller proceed without bundle sig
      #    discovery (rigor's vendored RBS still loads).
      def self.auto_detect(project_root:)
        from_config = read_bundle_config_path(project_root)
        return File.expand_path(from_config, project_root) if from_config

        vendor = File.join(project_root, "vendor", "bundle")
        return vendor if File.directory?(vendor)

        nil
      end

      def self.read_bundle_config_path(project_root)
        config_path = File.join(project_root, ".bundle", "config")
        return nil unless File.exist?(config_path)

        # `.bundle/config` is YAML with all-caps env-style keys.
        # `BUNDLE_PATH:` is the canonical key (Bundler 2.x); the
        # `--path` flag sets it.
        data = YAML.safe_load_file(config_path)
        return nil unless data.is_a?(Hash)

        data["BUNDLE_PATH"]
      rescue StandardError
        # Malformed `.bundle/config` should not break analysis;
        # silently skip auto-detection.
        nil
      end

      private_class_method :read_bundle_config_path
    end
  end
end
