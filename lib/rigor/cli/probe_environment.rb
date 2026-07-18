# frozen_string_literal: true

require_relative "../environment"
require_relative "../plugin"
require_relative "../plugin/loader"
require_relative "../plugin/services"
require_relative "../reflection"
require_relative "../type/combinator"

module Rigor
  class CLI
    # Shared construction of the analysis-observing environment for the single-shot probe commands
    # (`type-of`, `type-scan`, `trace`, `annotate`). Each of these answers "what does the engine infer here?"
    # for a hand-picked file or position, so the environment they type against MUST match the one `rigor check`
    # analyses with — otherwise a probe reports a type the real run never computes.
    #
    # The gap this closes: the probes historically built their environment with
    # `Environment.for_project(libraries:, signature_paths:)` only — no plugin registry, no `source_files:`. The
    # `source_rbs_synthesizer` plugin hook (ADR-32 / ADR-93's auto-wired `rigor-rbs-inline`) therefore never
    # ran there, so a class whose only signature comes from an inline `#: () -> void` annotation typed as
    # `Dynamic[top]` under a probe while `check` resolved it through the synthesized RBS. That divergence
    # misattributed a dispatch tier during the #162 transitive-void design pass (see the 2026-07-19 addendum in
    # docs/adr/100-static-diagnostic-family-and-void-origins.md).
    #
    # This threads the two things that were missing — the plugin registry built by the plugin loader, and the
    # `source_files:` the synthesizers run over — matching `rigor check`'s `Environment.for_project` call
    # (built in `Analysis::Runner::PoolCoordinator#build_runner_environment`). A probe legitimately simplifies
    # relative to check: no synthesis-failure reporter (a probe has no diagnostic pipeline) and no synthesis
    # cache store (a single-position probe recomputes cheaply). Plugin loading itself matches check — same
    # `.rigor.yml` `plugins:` config, same ADR-93 auto-wire (already applied by `Configuration.load`), same
    # `enabled:` / `require_magic_comment` semantics via `Plugin::Loader.load`.
    #
    # Fail-soft is the invariant: a project with no plugins, an unresolvable plugin gem, or any error during the
    # plugin-aware build degrades to the bare environment the probes used before — never a crash. `Plugin::Loader`
    # already isolates per-entry load failures onto the registry; the `rescue` here is the belt-and-suspenders
    # around anything the loader or the plugin-aware env build itself might raise.
    module ProbeEnvironment
      module_function

      # Builds the plugin-aware {Rigor::Environment} a probe types against.
      #
      # @param configuration [Rigor::Configuration] the loaded project configuration (already carries the
      #   ADR-93 auto-wired `rigor-rbs-inline` entry when the library is resolvable).
      # @param source_files [Array<String>] the file(s) the probe inspects. Threaded so each loaded plugin's
      #   `source_rbs_synthesizer` runs over them at env-build time; an empty list contributes no synthesized RBS.
      # @return [Rigor::Environment]
      def build(configuration:, source_files:)
        Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths,
          plugin_registry: load_plugin_registry(configuration),
          source_files: source_files
        )
      rescue StandardError
        bare(configuration)
      end

      # Loads the project's configured plugins the same way the plugin-inspection commands (`rigor plugins`,
      # `rigor doctor`) do: a `Plugin::Services` with no cache store (the probe recomputes) driving
      # `Plugin::Loader.load`. Returns `nil` — so `Environment.for_project` skips the plugin tier entirely —
      # when the project declares no plugins.
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

      # The pre-fix environment: RBS + project signatures only, no plugin tier and no synthesized RBS. The
      # fail-soft floor — a probe on a project with broken or absent plugin setup lands here and behaves exactly
      # as it did before this parity fix.
      def bare(configuration)
        Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )
      end
    end
  end
end
