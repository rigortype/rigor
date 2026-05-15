# frozen_string_literal: true

module Rigor
  class Environment
    # Open item O4 Layer 3 — Gemfile.lock parse.
    #
    # Parses a target project's `Gemfile.lock` via Bundler's
    # `LockfileParser` and exposes the locked gem set as a frozen
    # `Hash[String, LockfileResolver::LockedGem]` keyed by gem
    # name. Used by {Rigor::Environment::BundleSigDiscovery} as a
    # filter so the discovered `sig/` directories under the
    # bundler install root are limited to gems the project
    # actually declares (and at the version it declared them).
    #
    # The resolver is intentionally read-only. It does NOT load
    # the project's `Gemfile`, does NOT resolve dependencies,
    # does NOT touch the network, and does NOT require the
    # target project's Bundler context. It only reads bytes from
    # the lockfile.
    #
    # Failure modes are deliberately quiet: a missing or
    # malformed lockfile returns an empty map. The auto-detect
    # path is the configuration default; users who want hard
    # failures should pass an explicit `bundler.lockfile:` and
    # check the result via the stats banner.
    module LockfileResolver
      # Frozen value object for one locked gem entry.
      #
      # `version` is the resolved version string (e.g. "8.0.1");
      # `platform` is the lockfile's platform tag, normalised to
      # `"ruby"` when the lockfile records `ruby` and to the
      # raw String otherwise (e.g. "aarch64-linux-gnu").
      LockedGem = Data.define(:name, :version, :platform) do
        def initialize(name:, version:, platform:)
          super(
            name: -name.to_s,
            version: -version.to_s,
            platform: -platform.to_s
          )
        end
      end

      # @param lockfile_path [String, Pathname, nil] explicit path
      #   to the Gemfile.lock. When `nil`, falls back to
      #   `auto_detect` if `auto_detect:` is true.
      # @param project_root [String] resolution base for a
      #   relative `lockfile_path:` and the auto-detect search.
      # @param auto_detect [Boolean] when true and
      #   `lockfile_path:` is nil, look for
      #   `<project_root>/Gemfile.lock`.
      # @return [Hash{String => LockedGem}] frozen map of gem
      #   name → locked entry. Returns the empty frozen hash
      #   when no lockfile is resolvable, when the file is
      #   unreadable, or when Bundler refuses to parse it.
      def self.locked_gems(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
        resolved = resolve_lockfile_path(
          lockfile_path: lockfile_path,
          project_root: project_root,
          auto_detect: auto_detect
        )
        return EMPTY unless resolved

        parse(resolved)
      end

      # Returns the resolved lockfile path (`Pathname`) or `nil`
      # when neither explicit nor auto-detect produces one.
      # Public so the stats banner can show what rigor picked up.
      def self.resolve_lockfile_path(lockfile_path:, project_root: Dir.pwd, auto_detect: true)
        if lockfile_path
          path = Pathname.new(File.expand_path(lockfile_path.to_s, project_root))
          return path if path.file?

          return nil
        end

        return nil unless auto_detect

        candidate = Pathname.new(File.join(project_root, "Gemfile.lock"))
        candidate.file? ? candidate : nil
      end

      EMPTY = {}.freeze
      private_constant :EMPTY

      # Parses a Gemfile.lock at the given path. Bundler load
      # errors and malformed lockfile bytes both surface as the
      # empty frozen hash; analysis must not crash because a
      # lockfile is malformed. A single warning is emitted to
      # `$stderr` so the user can see why their lockfile was
      # ignored.
      def self.parse(path)
        require "bundler"
      rescue LoadError => e
        warn "rigor: cannot read #{path}: bundler is not available (#{e.message})"
        EMPTY
      else
        do_parse(path)
      end
      private_class_method :parse

      def self.do_parse(path)
        body = File.read(path.to_s)
        parser = Bundler::LockfileParser.new(body)
        locked = parser.specs.each_with_object({}) do |spec, h|
          # `Bundler::LazySpecification` carries name, version,
          # platform. Platform is `Gem::Platform` or the symbol
          # `:ruby`; both stringify cleanly. The upstream
          # bundler RBS shim (references/rbs/sig/shims/bundler.rbs)
          # does NOT declare `LazySpecification#platform` so the
          # call site needs a suppression marker.
          platform = spec.platform.to_s # rigor:disable undefined-method
          h[spec.name.to_s] = LockedGem.new(
            name: spec.name, version: spec.version.to_s, platform: platform
          )
        end
        locked.freeze
      rescue StandardError => e
        warn "rigor: ignoring malformed #{path} (#{e.class}: #{e.message})"
        EMPTY
      end
      private_class_method :do_parse
    end
  end
end
