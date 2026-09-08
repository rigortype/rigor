# frozen_string_literal: true

require_relative "environment"
require_relative "plugin"
require_relative "plugin/loader"
require_relative "plugin/services"
require_relative "reflection"
require_relative "type/combinator"

module Rigor
  # Shared construction of the project environment for every command that types against the project WITHOUT
  # driving a full {Analysis::Runner}: the single-shot probes (`type-of`, `type-scan`, `trace`, `annotate`) and
  # the `sig-gen` generator / observation collector. Each of these answers "what does the engine see here?" for
  # a hand-picked file, position or class, so the type universe they read MUST match the one `rigor check`
  # analyses against — otherwise the command reports, or declines to emit, against a universe the real run never
  # had.
  #
  # Two gaps this closes, both the same shape:
  #
  # - The probes historically built their environment with `Environment.for_project(libraries:,
  #   signature_paths:)` only — no plugin registry, no `source_files:`. The `source_rbs_synthesizer` plugin hook
  #   (ADR-32 / ADR-93's auto-wired `rigor-rbs-inline`) therefore never ran there, so a class whose only
  #   signature comes from an inline `#: () -> void` annotation typed as `Dynamic[top]` under a probe while
  #   `check` resolved it through the synthesized RBS. That divergence misattributed a dispatch tier during the
  #   #162 transitive-void design pass (see the 2026-07-19 addendum in
  #   docs/adr/100-static-diagnostic-family-and-void-origins.md).
  # - Neither the probes nor `sig-gen` passed the dependency-discovery axes — the `rbs collection` lockfile, the
  #   bundle's per-gem `sig/`, the Gemfile.lock gating them — that `check` reads straight off the same
  #   configuration. On a Rails project with `rbs collection install` run, `sig-gen` therefore could not see
  #   `ActiveRecord::Base` at all, and its superclass-without-RBS skip guard declined to emit every model
  #   (issue #821). The advice the guard prints — install the collection — had no effect, because the command
  #   never looked at it.
  #
  # {.dependency_discovery_options} is the single spelling of those axes; `Runner`'s build path
  # (`Analysis::Runner::PoolCoordinator#build_runner_environment`), the worker session and the LSP project
  # context read it too, so a new axis cannot be added to `check` and silently missed here.
  #
  # A non-`check` command legitimately simplifies in two places: no synthesis-failure reporter (there is no
  # diagnostic pipeline) and no synthesis cache store (a single-position probe recomputes cheaply). Plugin
  # loading itself matches check — same `.rigor.yml` `plugins:` config, same ADR-93 auto-wire (already applied
  # by `Configuration.load`), same `enabled:` / `require_magic_comment` semantics via `Plugin::Loader.load`.
  #
  # Fail-soft is the invariant: a project with no plugins, an unresolvable plugin gem, or any error during the
  # plugin-aware build degrades — never crashes. `Plugin::Loader` already isolates per-entry load failures onto
  # the registry; the `rescue` here is the belt-and-suspenders around anything the loader or the plugin-aware
  # env build itself might raise.
  module ProjectEnvironment
    module_function

    # Builds the plugin-aware, dependency-aware {Rigor::Environment} a non-`check` command works against.
    #
    # @param configuration — the loaded project configuration (already carries the
    #   ADR-93 auto-wired `rigor-rbs-inline` entry when the library is resolvable).
    # @param source_files — the file(s) the command inspects. Threaded so each loaded plugin's
    #   `source_rbs_synthesizer` runs over them at env-build time; an empty list contributes no synthesized RBS.
    def build(configuration:, source_files:)
      Environment.for_project(
        libraries: configuration.libraries,
        signature_paths: configuration.signature_paths,
        plugin_registry: load_plugin_registry(configuration),
        source_files: source_files,
        **dependency_discovery_options(configuration)
      )
    rescue StandardError
      bare(configuration)
    end

    # The dependency-discovery axes `check` reads off the configuration, as a keyword hash. Extracted so the
    # list lives in one place: every command that types against the project's real dependencies passes exactly
    # these, and adding an axis to `Environment.for_project` means adding it here once.
    def dependency_discovery_options(configuration)
      {
        bundler_bundle_path: configuration.bundler_bundle_path,
        bundler_auto_detect: configuration.bundler_auto_detect,
        bundler_lockfile: configuration.bundler_lockfile,
        rbs_collection_lockfile: configuration.rbs_collection_lockfile,
        rbs_collection_auto_detect: configuration.rbs_collection_auto_detect
      }
    end

    # Loads the project's configured plugins the same way the plugin-inspection commands (`rigor plugins`,
    # `rigor doctor`) do: a `Plugin::Services` with no cache store (these commands recompute) driving
    # `Plugin::Loader.load`. Returns `nil` — so `Environment.for_project` skips the plugin tier entirely — when
    # the project declares no plugins.
    def load_plugin_registry(configuration)
      return nil if configuration.plugins.empty?

      services = Plugin::Services.new(
        reflection: Reflection,
        type: Type::Combinator,
        configuration: configuration,
        cache_store: nil
      )
      Plugin::Loader.load(configuration: configuration, services: services)
    end

    # The first fail-soft floor: no plugin tier and no synthesized RBS, but still the project's own dependency
    # sources — dropping those is what issue #821 was, so a plugin-loading failure must not cost them.
    def bare(configuration)
      Environment.for_project(
        libraries: configuration.libraries,
        signature_paths: configuration.signature_paths,
        **dependency_discovery_options(configuration)
      )
    rescue StandardError
      minimal(configuration)
    end

    # The last floor: RBS core plus the project's own signature paths, which cannot fail on anything outside
    # the project itself.
    def minimal(configuration)
      Environment.for_project(
        libraries: configuration.libraries,
        signature_paths: configuration.signature_paths
      )
    end
  end
end
