# frozen_string_literal: true

module Rigor
  module Effects
    # The named entry-point presets `effects.snapshot.reach:` may adopt (ADR-103 WD14).
    #
    # `reach:` entries are of two kinds, told apart syntactically:
    #
    # - a **path glob** — anything carrying a glob or path character (`* ? [ ] / .`) — matched against the
    #   project-relative file a method is defined in, with the `rigor unused --entry-point` semantics
    #   (`File.fnmatch?` with `File::FNM_PATHNAME`, so `**` is the only way across a directory boundary);
    # - a **preset name** — a bare `[a-z0-9_-]+` token — resolved here to the globs the preset stands for.
    #
    # **This slice ships no presets.** They are named by the plugin that models a framework (rigor-rails'
    # controller actions, `perform`, mailer methods, channels) through a manifest field, which lands with
    # the Rails slice; the registry exists now so the config key has its final meaning and an unknown name
    # is a visible load-time error rather than a glob that silently matches nothing.
    #
    # Registration is process-global and happens before a snapshot is built, in the parent process — the
    # same shape the other CLI-time registries take. Nothing here crosses a fork or a Ractor boundary.
    module EntryPoints
      # What makes a `reach:` entry a path glob rather than a preset name. Kept deliberately wide: a name
      # that looks at all like a path is read as one, because a mistyped preset that matched a file would
      # be the confusing failure.
      GLOB_CHARACTERS = %r{[*?\[\]/.]}

      # What a preset name may be spelled with, so a malformed name is rejected at registration rather
      # than becoming an unfindable key.
      NAME_PATTERN = /\A[a-z0-9][a-z0-9_-]*\z/

      class Error < StandardError
      end

      @presets = {}

      class << self
        # Whether `entry` is a path glob rather than a preset name.
        def glob?(entry)
          GLOB_CHARACTERS.match?(entry)
        end

        # Registers `name` as standing for `globs`. Re-registering the same name with the same globs is a
        # no-op, so a plugin loaded twice in one process does not raise.
        def register(name, globs)
          key = name.to_s
          raise Error, "not a well-formed entry-point preset name: #{key.inspect}" unless NAME_PATTERN.match?(key)

          patterns = Array(globs).map(&:to_s).uniq.sort.freeze
          existing = @presets[key]
          return key if existing == patterns
          raise Error, "entry-point preset already registered with different globs: #{key.inspect}" if existing

          @presets[key] = patterns
          key
        end

        def known?(name)
          @presets.key?(name.to_s)
        end

        # Every registered preset name, sorted. Empty in this slice.
        def names
          @presets.keys.sort.freeze
        end

        # The globs `name` stands for, or `nil` when nothing registered it.
        def globs_for(name)
          @presets[name.to_s]
        end

        # Drops every registration. For specs only — production code registers and never unregisters.
        def reset!
          @presets = {}
        end
      end
    end
  end
end
