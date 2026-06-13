# frozen_string_literal: true

require_relative "../diagnostic"

module Rigor
  module Analysis
    class Runner
      # Builds and orders every project-level diagnostic stream the
      # {Runner} surfaces — the pre-file streams (plugin load / prepare,
      # ADR-10 dependency-source, pre-eval, RBS coverage, path errors),
      # the post-analysis streams (synthesized namespaces, conforms-to,
      # the three reporter drains), and the final severity stamp.
      #
      # Constraint: the relative order of every stream below is the
      # diagnostic output contract — callers MUST NOT reorder the
      # concatenation in `pre_file_diagnostics` or the post-analysis
      # streams the {Runner} drains after `analyze_files`.
      #
      # The collaborator holds the immutable per-run inputs (the
      # configuration and the three mutable reporter accumulators, which
      # are shared instances the dispatcher records into). The per-run
      # varying state produced by other passes (the plugin registry, the
      # dependency-source index, and the four end-of-pass snapshots) is
      # read through injected reader procs so this collaborator never
      # calls back into the {Runner} and the read happens at the exact
      # point in the run the original inline read did.
      class DiagnosticAggregator # rubocop:disable Metrics/ClassLength
        # @param configuration [Rigor::Configuration]
        # @param rbs_extended_reporter [RbsExtended::Reporter]
        # @param boundary_cross_reporter
        #   [DependencySourceInference::BoundaryCrossReporter]
        # @param source_rbs_synthesis_reporter
        #   [Plugin::SourceRbsSynthesisReporter]
        # @param plugin_registry [#call] reader returning the current
        #   {Plugin::Registry} (varies per run).
        # @param dependency_source_index [#call] reader returning the
        #   current {DependencySourceInference::Index}.
        # @param pool_mode [#call] reader returning the pool-mode flag.
        # @param cached_plugin_prepare_diagnostics [#call] reader
        #   returning the prepare-diagnostic snapshot.
        # @param pre_eval_diagnostics_from_scanner [#call] reader
        #   returning the pre-eval scanner diagnostics.
        # @param synthesized_namespaces_snapshot [#call] reader.
        # @param conformance_results_snapshot [#call] reader.
        def initialize(configuration:, rbs_extended_reporter:, boundary_cross_reporter:, # rubocop:disable Metrics/ParameterLists
                       source_rbs_synthesis_reporter:, plugin_registry:, dependency_source_index:,
                       pool_mode:, cached_plugin_prepare_diagnostics:,
                       pre_eval_diagnostics_from_scanner:, synthesized_namespaces_snapshot:,
                       conformance_results_snapshot:)
          @configuration = configuration
          @rbs_extended_reporter = rbs_extended_reporter
          @boundary_cross_reporter = boundary_cross_reporter
          @source_rbs_synthesis_reporter = source_rbs_synthesis_reporter
          @plugin_registry_reader = plugin_registry
          @dependency_source_index_reader = dependency_source_index
          @pool_mode_reader = pool_mode
          @cached_plugin_prepare_diagnostics_reader = cached_plugin_prepare_diagnostics
          @pre_eval_diagnostics_from_scanner_reader = pre_eval_diagnostics_from_scanner
          @synthesized_namespaces_snapshot_reader = synthesized_namespaces_snapshot
          @conformance_results_snapshot_reader = conformance_results_snapshot
        end

        # Pre-file diagnostic streams that fire once per run rather
        # than per analyzed file: plugin load / prepare envelopes,
        # the ADR-10 dependency-source resolution surface, and the
        # `expand_paths` errors for `paths:` entries that don't
        # exist or aren't `.rb`. Aggregated here so `#run` stays
        # under the ABC budget.
        #
        # ADR-15 Phase 4b — `plugin_prepare_diagnostics` runs on
        # the coordinator's plugin registry under sequential mode;
        # under pool mode each worker re-runs `prepare` against
        # its own plugin instances, so the pool path drains the
        # first worker's prepare-diagnostic snapshot into the
        # aggregated diagnostic stream instead (see
        # {#analyze_files_in_pool}). Skipping the coordinator
        # prepare in pool mode avoids double-running `#prepare`
        # against the coordinator-side plugin instances (which
        # the pool path never consults for per-file analysis).
        def pre_file_diagnostics(expansion)
          # ADR-18 slice 3 — prepare diagnostics are captured
          # earlier in #run (before the synthetic-method scanner)
          # so cross-plugin facts are available to the scanner.
          # We re-surface the captured diagnostics here so the
          # existing pre_file_diagnostics ordering is preserved.
          prepare = pool_mode? ? [] : cached_plugin_prepare_diagnostics
          plugin_load_diagnostics +
            prepare +
            pre_eval_diagnostics +
            dependency_source_diagnostics +
            dependency_source_budget_diagnostics +
            dependency_source_config_conflict_diagnostics +
            rbs_coverage_diagnostics +
            expansion.fetch(:errors)
        end

        # ADR-17 slice 1 — surface a `:error` diagnostic for each
        # `pre_eval:` entry whose resolved path doesn't exist on
        # disk. Loud failure mode (`:error`, not `:warning`):
        # a missing pre_eval path is a configuration mistake the
        # user must fix before analysis is meaningful.
        #
        # Slice 2 adds the `:warning` `pre-eval.parse-error`
        # stream from the pre-pass scanner — accumulated as
        # `@pre_eval_diagnostics_from_scanner` during {#run} and
        # merged here so both diagnostics flow through the same
        # severity / ordering pipeline.
        def pre_eval_diagnostics
          not_found = @configuration.pre_eval.filter_map do |path|
            next if File.file?(path)

            Diagnostic.new(
              path: ".rigor.yml", line: 1, column: 1,
              message: "pre_eval entry not found: #{path.inspect}. " \
                       "Pre-evaluation requires the file to exist on disk; remove the entry " \
                       "or create the file before re-running analysis.",
              severity: :error,
              rule: "pre-eval.file-not-found",
              source_family: :builtin
            )
          end
          not_found + Array(pre_eval_diagnostics_from_scanner).map { |hash| diagnostic_from_hash(hash) }
        end

        def diagnostic_from_hash(hash)
          Diagnostic.new(
            path: hash.fetch(:path), line: hash.fetch(:line), column: hash.fetch(:column),
            message: hash.fetch(:message), severity: hash.fetch(:severity),
            rule: hash.fetch(:rule), source_family: :builtin
          )
        end

        def plugin_load_diagnostics
          plugin_registry.load_errors.map do |error|
            Diagnostic.new(
              path: ".rigor.yml",
              line: 1,
              column: 1,
              message: error.message,
              severity: :error,
              rule: "load-error",
              source_family: :plugin_loader
            )
          end
        end

        # ADR-10 § "Diagnostic prefix family" — surfaces gems
        # listed in `dependencies.source_inference` that RubyGems
        # could not resolve. The run continues; the gem simply
        # contributes nothing this session, mirroring the
        # plugin-load error envelope. Authored `:warning` because
        # an unresolvable gem usually means a typo or a missing
        # `bundle install` rather than a project-blocking problem;
        # the severity profile still re-stamps it.
        def dependency_source_diagnostics
          dependency_source_index.unresolvable.map do |entry|
            Diagnostic.new(
              path: ".rigor.yml",
              line: 1,
              column: 1,
              message: "dependencies.source_inference[].gem #{entry.gem_name.inspect} could not be " \
                       "resolved (#{entry.reason}); skipping",
              severity: :warning,
              rule: "dynamic.dependency-source.gem-not-found",
              source_family: :builtin
            )
          end
        end

        # ADR-10 § "Budget interaction" / slice 4 — emits one
        # `:warning` per gem whose Walker run hit the
        # `dependencies.budget_per_gem` cap. The cap is a Walker-
        # side guard rail (slice 4 picks the (α) semantics from
        # ADR-10 WD4: harvesting stops, the dispatcher behaves
        # exactly as before for unrecorded methods). The
        # diagnostic names the gem and points the user at the
        # three remediations: ship RBS, reduce `mode:` from
        # `full` to `when_missing`, or de-list the gem.
        # ADR-10 § "config-conflict diagnostic" / 5d — surfaces
        # `Configuration::Dependencies` warnings accumulated
        # during `from_h` deduplication of the `includes:`-chain
        # source_inference array. Each warning describes a
        # per-gem mode conflict that the merge resolved
        # right-wins; the user sees one diagnostic per conflict.
        # `:warning` matches the user's "warn but don't block"
        # preference per the design discussion.
        def dependency_source_config_conflict_diagnostics
          @configuration.dependencies.warnings.map do |message|
            Diagnostic.new(
              path: ".rigor.yml",
              line: 1,
              column: 1,
              message: message,
              severity: :warning,
              rule: "dynamic.dependency-source.config-conflict",
              source_family: :builtin
            )
          end
        end

        def dependency_source_budget_diagnostics
          budget = @configuration.dependencies.budget_per_gem
          dependency_source_index.budget_exceeded.map do |gem_name|
            Diagnostic.new(
              path: ".rigor.yml",
              line: 1,
              column: 1,
              message: "dependencies.source_inference[].gem #{gem_name.inspect} exceeded the per-gem " \
                       "catalog cap (#{budget} method definitions); the remaining methods fall back " \
                       "to the existing RBS-or-Dynamic[top] boundary. Ship RBS for the gem, set " \
                       "`mode: when_missing` instead of `full`, or de-list the gem.",
              severity: :warning,
              rule: "dynamic.dependency-source.budget-exceeded",
              source_family: :builtin
            )
          end
        end

        # O4 Layer 3 slice 3 — graceful-degradation coverage
        # report. When the project has a `Gemfile.lock` (slice 1)
        # and one or more locked gems are not covered by ANY of
        # the four RBS resolution paths (`DEFAULT_LIBRARIES`,
        # `data/vendored_gem_sigs/`, slice-1 bundle-shipped
        # `sig/`, slice-2 `rbs_collection.lock.yaml`), emit a
        # single `:info` diagnostic summarising the uncovered set
        # so the user can act on it (run `rbs collection install`,
        # opt the gem into `dependencies.source_inference:`, or
        # accept the `Dynamic[T]` fallback).
        #
        # Suppressed when the lockfile is empty, when every gem
        # is covered, or when slice 1's `bundler.lockfile`
        # discovery returned nothing (no lockfile to read).
        def rbs_coverage_diagnostics
          locked = Environment::LockfileResolver.locked_gems(
            lockfile_path: @configuration.bundler_lockfile,
            project_root: Dir.pwd,
            auto_detect: @configuration.bundler_auto_detect
          )
          return [] if locked.empty?

          bundle_sig_paths = Environment::BundleSigDiscovery.discover(
            bundle_path: @configuration.bundler_bundle_path,
            project_root: Dir.pwd,
            auto_detect: @configuration.bundler_auto_detect,
            locked_gems: locked
          )
          collection_paths = Environment::RbsCollectionDiscovery.discover(
            lockfile_path: @configuration.rbs_collection_lockfile,
            project_root: Dir.pwd,
            auto_detect: @configuration.rbs_collection_auto_detect
          )
          rows = Environment::RbsCoverageReport.classify(
            locked_gems: locked,
            default_libraries: Environment::DEFAULT_LIBRARIES,
            bundle_sig_paths: bundle_sig_paths,
            rbs_collection_paths: collection_paths
          )
          missing = Environment::RbsCoverageReport.missing(rows)
          return [] if missing.empty?

          [build_rbs_coverage_missing_diagnostic(missing)]
        end

        # Robustness uplift companion (ADR-5) — when the project's
        # `signature_paths:` RBS declared qualified names without their
        # enclosing namespace, `RbsLoader` synthesizes the missing
        # `module`s so the otherwise-inert signatures resolve. Surface a
        # single `:info` diagnostic naming them so the user knows their
        # sig set is malformed (`rbs validate` rejects it) and can fix it
        # at the source. Authored `:info`: the analysis already succeeded;
        # this is advisory, never a gate. Empty for a well-formed sig set.
        def rbs_synthesized_namespace_diagnostics
          synthesized = synthesized_namespaces_snapshot
          return [] if synthesized.nil? || synthesized.empty?

          [build_rbs_synthesized_namespace_diagnostic(synthesized)]
        end

        # Maps the per-run `rigor:v1:conforms-to` scan results into
        # diagnostics (spec: `rbs-extended.md` § "Explicit conformance
        # directive"). A class that declares `conforms-to _Interface`
        # but is missing a required interface method surfaces as
        # `rbs_extended.unsatisfied-conformance`; an unresolvable
        # interface name surfaces as `dynamic.rbs-extended.unresolved`
        # `:info` (the same fail-soft channel the other directive
        # parsers use). Empty for a project with no directive, a
        # well-formed conformance, or a non-sequential pool run (the
        # snapshot mirrors `synthesized_namespaces`).
        def conforms_to_diagnostics
          results = conformance_results_snapshot
          return [] if results.nil? || results.empty?

          results.map { |record| build_conformance_diagnostic(record) }
        end

        def build_conformance_diagnostic(record)
          case record
          when RbsExtended::ConformanceChecker::Unsatisfied
            build_unsatisfied_conformance_diagnostic(record)
          when RbsExtended::ConformanceChecker::IncompatibleSignature
            build_incompatible_signature_diagnostic(record)
          else # UnresolvedInterface
            build_reporter_diagnostic(
              record.location,
              rule: "dynamic.rbs-extended.unresolved",
              message: "`#{record.class_name}` declares `conforms-to #{record.interface_name}` but " \
                       "interface `#{record.interface_name}` is not loaded. Check for a typo or add " \
                       "the `sig`/library that declares it to the RBS load path."
            )
          end
        end

        def build_unsatisfied_conformance_diagnostic(record)
          path, line, column = location_fields(record.location)
          Diagnostic.new(
            path: path, line: line, column: column,
            message: "`#{record.class_name}` declares `conforms-to #{record.interface_name}` " \
                     "but does not provide #{pluralize_methods(record.missing_methods)}: " \
                     "#{record.missing_methods.map { |m| "`##{m}`" }.join(', ')}. Implement the " \
                     "missing method(s) or remove the directive.",
            severity: :warning,
            rule: "rbs_extended.unsatisfied-conformance",
            source_family: :builtin
          )
        end

        def build_incompatible_signature_diagnostic(record)
          path, line, column = location_fields(record.location)
          Diagnostic.new(
            path: path, line: line, column: column,
            message: "`#{record.class_name}##{record.method_name}` does not satisfy " \
                     "`conforms-to #{record.interface_name}`: #{record.detail}. Adjust the " \
                     "signature to a subtype of the interface contract.",
            severity: :warning,
            rule: "rbs_extended.unsatisfied-conformance",
            source_family: :builtin,
            method_name: record.method_name
          )
        end

        def pluralize_methods(methods)
          methods.size == 1 ? "required method" : "#{methods.size} required methods"
        end

        def build_rbs_synthesized_namespace_diagnostic(synthesized)
          sample_size = 5
          sample = synthesized.first(sample_size)
          suffix = synthesized.size > sample_size ? ", and #{synthesized.size - sample_size} more" : ""
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "#{synthesized.size} RBS namespace(s) under `signature_paths:` are " \
                     "referenced by qualified declarations (e.g. `class Foo::Bar`) but never " \
                     "declared: #{sample.join(', ')}#{suffix}. `rbs validate` rejects this; " \
                     "Rigor synthesized the missing `module`(s) so the signatures still " \
                     "resolve. Declare each (`module <name>` / `class <name>`) in your RBS to " \
                     "make the sig set valid upstream.",
            severity: :info,
            rule: "rbs.coverage.synthesized-namespace",
            source_family: :builtin
          )
        end

        def build_rbs_coverage_missing_diagnostic(missing)
          sample_size = 5
          sample = missing.first(sample_size).map(&:gem_name)
          suffix = missing.size > sample_size ? ", and #{missing.size - sample_size} more" : ""
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "#{missing.size} gem(s) in Gemfile.lock have no RBS available: " \
                     "#{sample.join(', ')}#{suffix}. " \
                     "Consider `rbs collection install` to fetch community RBS from " \
                     "`ruby/gem_rbs_collection`, ship `sig/` in the gem itself, or " \
                     "opt the gem into `dependencies.source_inference:` in `.rigor.yml`.",
            severity: :info,
            rule: "rbs.coverage.missing-gem",
            source_family: :builtin
          )
        end

        # ADR-13 slice 3b — drains the per-run
        # {RbsExtended::Reporter} into one diagnostic per accumulated
        # event:
        #
        # - `dynamic.rbs-extended.unresolved` for every annotation
        #   payload the parser could not turn into a {Rigor::Type}.
        #   Surfaces typos and references to plugin-supplied names
        #   the project did not enable.
        # - `dynamic.shape.lossy-projection` for every shape-projection
        #   type function (`pick_of`, …) applied to a carrier that
        #   loses precision (anything other than `HashShape` / `Tuple`).
        #
        # Both are authored `:info`; the severity profile re-stamps
        # them per project taste. Path / line / column come from the
        # annotation's `RBS::Location` when available, falling back
        # to `.rigor.yml`-style file-level attribution otherwise.
        def rbs_extended_reporter_diagnostics
          return [] if @rbs_extended_reporter.empty?

          unresolved = @rbs_extended_reporter.unresolved_payloads.map do |entry|
            build_reporter_diagnostic(
              entry.source_location,
              rule: "dynamic.rbs-extended.unresolved",
              message: "`RBS::Extended` directive payload could not be resolved: " \
                       "#{entry.payload.inspect}. Check for typos or enable a plugin " \
                       "that contributes the referenced type vocabulary."
            )
          end

          lossy = @rbs_extended_reporter.lossy_projections.map do |entry|
            build_reporter_diagnostic(
              entry.source_location,
              rule: "dynamic.shape.lossy-projection",
              message: "Shape projection `#{entry.head}` applied to a carrier without a " \
                       "literal shape; the projection degrades to the input type. Author " \
                       "a `HashShape` / `Tuple` carrier or accept the unchanged result."
            )
          end

          unresolved + lossy
        end

        # ADR-10 slice 5c — drains the per-run
        # {DependencySourceInference::BoundaryCrossReporter} into
        # `dynamic.dependency-source.boundary-cross` `:info`
        # diagnostics. Each event flags a call site where RBS
        # dispatch produced a concrete answer AND a `mode: :full`
        # opt-in gem's source catalog ALSO contains an entry for
        # the same `(class_name, method_name)` — i.e., both
        # contracts have an opinion. RBS still wins on the
        # dispatch result; the diagnostic is purely advisory so
        # the user can verify the two contracts haven't drifted.
        #
        # Severity profile re-stamps the rule per project taste.
        # The diagnostic carries no `path` / `line` / `column`
        # because the crossing is per-method-per-gem, not
        # per-call-site — the diagnostic anchors at `.rigor.yml`
        # like the other `dependency-source.*` diagnostics that
        # report on opt-in configuration.
        # ADR-32 WD6 — drains the per-run
        # {Plugin::SourceRbsSynthesisReporter} into
        # `source-rbs-synthesis-failed` `:info` diagnostics. Each
        # entry names the plugin that owns the synthesizer, the
        # source file the rbs-inline parser couldn't process, and
        # the upstream error message. The synthesizer-emitting
        # plugin (currently only `rigor-rbs-inline`) treats a
        # parse failure as a no-contribution event so analysis
        # continues; this stream surfaces the failure so the user
        # can see which files contributed nothing and why.
        #
        # Severity profile re-stamps the rule per project taste.
        def source_rbs_synthesis_diagnostics
          return [] if @source_rbs_synthesis_reporter.empty?

          @source_rbs_synthesis_reporter.entries.map do |entry|
            Diagnostic.new(
              path: entry.path, line: 1, column: 1,
              message: "plugin `#{entry.plugin_id}` failed to synthesise RBS from this file: " \
                       "#{entry.message}. The file's analysis falls back to no inline-RBS " \
                       "contribution. Fix the inline-RBS comment grammar or remove the " \
                       "annotation to silence this diagnostic.",
              severity: :info,
              rule: "source-rbs-synthesis-failed",
              source_family: :builtin
            )
          end
        end

        def boundary_cross_diagnostics
          return [] if @boundary_cross_reporter.empty?

          @boundary_cross_reporter.entries.map do |entry|
            Diagnostic.new(
              path: ".rigor.yml", line: 1, column: 1,
              message: "`#{entry.class_name}##{entry.method_name}` is contributed by both " \
                       "RBS (#{entry.rbs_display}) and the `mode: :full` opt-in gem " \
                       "`#{entry.gem_name}`. RBS wins on dispatch; verify the gem source " \
                       "has not drifted from its RBS contract.",
              severity: :info,
              rule: "dynamic.dependency-source.boundary-cross",
              source_family: :builtin
            )
          end
        end

        def build_reporter_diagnostic(source_location, rule:, message:)
          path, line, column = location_fields(source_location)
          Diagnostic.new(
            path: path, line: line, column: column,
            message: message, severity: :info, rule: rule, source_family: :builtin
          )
        end

        def location_fields(source_location)
          return [".rigor.yml", 1, 1] if source_location.nil?

          path = location_path(source_location)
          line = source_location.respond_to?(:start_line) ? source_location.start_line : 1
          column = source_location.respond_to?(:start_column) ? source_location.start_column + 1 : 1
          [path, line, column]
        rescue StandardError
          [".rigor.yml", 1, 1]
        end

        def location_path(source_location)
          buffer = source_location.respond_to?(:buffer) ? source_location.buffer : nil
          return ".rigor.yml" if buffer.nil? || !buffer.respond_to?(:name)

          name = buffer.name.to_s
          name.empty? ? ".rigor.yml" : name
        end

        # ADR-8 § "Severity profile" — re-stamps each diagnostic's
        # severity from the configured profile + per-rule
        # overrides. Rules emit with their authored severity; the
        # profile is the final filter. Diagnostics whose resolved
        # severity is `:off` are dropped from the run result.
        def apply_severity_profile(diagnostics)
          diagnostics.filter_map { |diagnostic| stamp_severity(diagnostic) }
        end

        def stamp_severity(diagnostic)
          return diagnostic if diagnostic.rule.nil?

          resolved = Configuration::SeverityProfile.resolve(
            rule: diagnostic.rule,
            authored_severity: diagnostic.severity,
            profile: @configuration.severity_profile,
            overrides: @configuration.severity_overrides,
            bleeding_edge_overrides: @configuration.bleeding_edge_severity_overrides
          )
          return nil if resolved == :off
          return diagnostic if resolved == diagnostic.severity

          Diagnostic.new(
            path: diagnostic.path,
            line: diagnostic.line,
            column: diagnostic.column,
            message: diagnostic.message,
            severity: resolved,
            rule: diagnostic.rule,
            source_family: diagnostic.source_family
          )
        end

        private

        def plugin_registry
          @plugin_registry_reader.call
        end

        def dependency_source_index
          @dependency_source_index_reader.call
        end

        def pool_mode?
          @pool_mode_reader.call
        end

        def cached_plugin_prepare_diagnostics
          @cached_plugin_prepare_diagnostics_reader.call
        end

        def pre_eval_diagnostics_from_scanner
          @pre_eval_diagnostics_from_scanner_reader.call
        end

        def synthesized_namespaces_snapshot
          @synthesized_namespaces_snapshot_reader.call
        end

        def conformance_results_snapshot
          @conformance_results_snapshot_reader.call
        end
      end
    end
  end
end
