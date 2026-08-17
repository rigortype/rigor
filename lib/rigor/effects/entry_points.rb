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
    # Presets are named by the plugin that models a framework — rigor-actionpack's controller actions,
    # rigor-activejob's `perform`, rigor-actionmailer's mailer methods, rigor-actioncable's channels —
    # through the `effect_entry_points:` manifest field (#387), and registered here through
    # {.register_all} once the plugin set is loaded. `Configuration` checks only that a `reach:` entry is
    # SHAPED like a preset name; the existence check runs where the snapshot expands it, which is the
    # first point at which the registered set is complete.
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

        # Whether `entry` is spelled like a preset name at all — the shape check `Configuration` runs at
        # load, before any plugin has had the chance to register one.
        def name?(entry)
          NAME_PATTERN.match?(entry)
        end

        # Registers every `effect_entry_points:` preset the loaded plugins declare. Idempotent per name +
        # glob set, so two runs in one process (the spec suite, the LSP) do not collide; two plugins
        # claiming one name with different globs is a genuine conflict and raises.
        def register_all(presets)
          Array(presets).each { |preset| register(preset.name, preset.globs) }
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
