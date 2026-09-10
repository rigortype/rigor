# frozen_string_literal: true

require_relative "../crash_signature"
require_relative "../diagnostic"
require_relative "../severity_stamp"

module Rigor
  module Analysis
    class Runner
      # Builds and orders every project-level diagnostic stream the {Runner} surfaces — the pre-file
      # streams (plugin load / prepare, ADR-10 dependency-source, pre-eval, RBS coverage, path errors), the
      # post-analysis streams (synthesized namespaces, conforms-to, the three reporter drains), and the
      # final severity stamp.
      #
      # Constraint: the relative order of every stream below is the diagnostic output contract — callers
      # MUST NOT reorder the concatenation in `pre_file_diagnostics` or the post-analysis streams the
      # {Runner} drains after `analyze_files`.
      #
      # The collaborator holds the immutable per-run inputs (the configuration and the three mutable
      # reporter accumulators, which are shared instances the dispatcher records into). The per-run varying
      # state produced by other passes (the plugin registry, the dependency-source index, and the four
      # end-of-pass snapshots) is read through injected reader procs so this collaborator never calls back
      # into the {Runner} and the read happens at the exact point in the run the original inline read did.
      class DiagnosticAggregator # rubocop:disable Metrics/ClassLength
        # @param plugin_registry — reader returning the current {Plugin::Registry} (varies per run).
        # @param dependency_source_index — reader returning the current
        #   {DependencySourceInference::Index}.
        # @param pool_mode — reader returning the pool-mode flag.
        # @param cached_plugin_prepare_diagnostics — reader returning the prepare-diagnostic snapshot.
        # @param pre_eval_diagnostics_from_scanner — reader returning the pre-eval scanner diagnostics.
        # @param synthesized_namespaces_snapshot — reader.
        # @param quarantined_signatures_snapshot — reader returning the `signature_paths:` files skipped
        #   because they do not parse (`[path, first_error_line]` pairs).
        # @param signature_standdowns_snapshot — reader returning the plugin-contributed signature files
        #   that stood down against a colliding generic arity (#610), as
        #   `[path, class_name, existing_arity, incoming_arity, existing_file]` tuples. Defaults to none so
        #   a caller that snapshots nothing of the kind need not say so.
        # @param env_build_failure_snapshot — reader returning the total RBS env-build failure tuple
        #   (`[error_class, first_error_line, conflicting_buffer_names]`) or nil when the env built.
        # @param definition_build_failures_snapshot — issue #696 — reader returning the per-class
        #   `RBS::DefinitionBuilder` failures the run observed, as `[class_name, error_class, member,
        #   conflicting_buffer_names]` tuples. Empty for a healthy sig set.
        # @param hkt_scan_failure_snapshot — issue #784 — reader returning the `[error_class_name,
        #   first_message_line, raw_frame_or_nil, stage]` tuple whichever stage of the HKT-registry build
        #   raised, or nil when both built (or were never demanded). `stage` is `:scan` (the RBS `type`-alias
        #   scan) or `:overlay` (the plugin-manifest aggregation, #791), and picks the row's wording.
        # @param conformance_results_snapshot — reader.
        def initialize(configuration:, rbs_extended_reporter:, boundary_cross_reporter:, # rubocop:disable Metrics/ParameterLists
                       source_rbs_synthesis_reporter:, plugin_registry:, dependency_source_index:,
                       pool_mode:, cached_plugin_prepare_diagnostics:,
                       pre_eval_diagnostics_from_scanner:, synthesized_namespaces_snapshot:,
                       quarantined_signatures_snapshot:, env_build_failure_snapshot:,
                       definition_build_failures_snapshot:, hkt_scan_failure_snapshot:,
                       conformance_results_snapshot:, signature_standdowns_snapshot: -> { [] })
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
          @quarantined_signatures_snapshot_reader = quarantined_signatures_snapshot
          @signature_standdowns_snapshot_reader = signature_standdowns_snapshot
          @env_build_failure_snapshot_reader = env_build_failure_snapshot
          @definition_build_failures_snapshot_reader = definition_build_failures_snapshot
          @hkt_scan_failure_snapshot_reader = hkt_scan_failure_snapshot
          @conformance_results_snapshot_reader = conformance_results_snapshot
        end

        # Pre-file diagnostic streams that fire once per run rather than per analyzed file: plugin load /
        # prepare envelopes, the ADR-10 dependency-source resolution surface, and the `expand_paths` errors
        # for `paths:` entries that don't exist or aren't `.rb`. Aggregated here so `#run` stays under the
        # ABC budget.
        #
        # ADR-15 Phase 4b — `plugin_prepare_diagnostics` runs on the coordinator's plugin registry under
        # sequential mode; under pool mode each worker re-runs `prepare` against its own plugin instances,
        # so the pool path drains the first worker's prepare-diagnostic snapshot into the aggregated
        # diagnostic stream instead (see {#analyze_files_in_pool}). Skipping the coordinator prepare in pool
        # mode avoids double-running `#prepare` against the coordinator-side plugin instances (which the
        # pool path never consults for per-file analysis).
        def pre_file_diagnostics(expansion)
          # ADR-18 slice 3 — prepare diagnostics are captured earlier in #run (before the synthetic-method
          # scanner) so cross-plugin facts are available to the scanner. We re-surface the captured
          # diagnostics here so the existing pre_file_diagnostics ordering is preserved.
          prepare = pool_mode? ? [] : cached_plugin_prepare_diagnostics
          plugin_load_diagnostics +
            prepare +
            pre_eval_diagnostics +
            dependency_source_diagnostics +
            dependency_source_budget_diagnostics +
            dependency_source_config_conflict_diagnostics +
            rbs_coverage_diagnostics +
            rbs_inline_annotation_hint_diagnostics(expansion) +
            expansion.fetch(:errors)
        end

        # ADR-17 slice 1 — surface a `:error` diagnostic for each `pre_eval:` entry whose resolved path
        # doesn't exist on disk. Loud failure mode (`:error`, not `:warning`): a missing pre_eval path is a
        # configuration mistake the user must fix before analysis is meaningful.
        #
        # Slice 2 adds the `:warning` `pre-eval.parse-error` stream from the pre-pass scanner — accumulated
        # as `@pre_eval_diagnostics_from_scanner` during {#run} and merged here so both diagnostics flow
        # through the same severity / ordering pipeline.
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
              message: plugin_load_error_message(error),
              severity: :error,
              rule: "load-error",
              source_family: :plugin_loader
            )
          end
        end

        # #194 slice 1 — when the require SUCCEEDED but configuration / instantiation then failed, the loader
        # stamps the resolved file on the error; naming it here turns an engine↔plugin version skew (a stale
        # installed `rigortype` gem shadowing a checkout's bundled plugin) into a one-line diagnosis. A
        # require that failed outright carries no resolved path and keeps its original message.
        def plugin_load_error_message(error)
          return error.message if error.resolved_path.nil?

          "#{error.message} (loaded from #{error.resolved_path})"
        end

        # ADR-10 § "Diagnostic prefix family" — surfaces gems listed in `dependencies.source_inference`
        # that RubyGems could not resolve. The run continues; the gem simply contributes nothing this
        # session, mirroring the plugin-load error envelope. Authored `:warning` because an unresolvable
        # gem usually means a typo or a missing `bundle install` rather than a project-blocking problem; the
        # severity profile still re-stamps it.
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

        # ADR-10 § "Budget interaction" / slice 4 — emits one `:warning` per gem whose Walker run hit the
        # `dependencies.budget_per_gem` cap. The cap is a Walker- side guard rail (slice 4 picks the (α)
        # semantics from ADR-10 WD4: harvesting stops, the dispatcher behaves exactly as before for
        # unrecorded methods). The diagnostic names the gem and points the user at the three remediations:
        # ship RBS, reduce `mode:` from `full` to `when_missing`, or de-list the gem.
        # ADR-10 § "config-conflict diagnostic" / 5d — surfaces `Configuration::Dependencies` warnings
        # accumulated during `from_h` deduplication of the `includes:`-chain source_inference array. Each
        # warning describes a per-gem mode conflict that the merge resolved right-wins; the user sees one
        # diagnostic per conflict. `:warning` matches the user's "warn but don't block" preference per the
        # design discussion.
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

        # O4 Layer 3 slice 3 — graceful-degradation coverage report. When the project has a `Gemfile.lock`
        # (slice 1) and one or more locked gems are not covered by ANY of the four RBS resolution paths
        # (`DEFAULT_LIBRARIES`, `data/vendored_gem_sigs/`, slice-1 bundle-shipped `sig/`, slice-2
        # `rbs_collection.lock.yaml`), emit a single `:info` diagnostic summarising the uncovered set so the
        # user can act on it (run `rbs collection install`, opt the gem into `dependencies.source_inference:`,
        # or accept the `Dynamic[T]` fallback).
        #
        # Suppressed when the lockfile is empty, when every gem is covered, or when slice 1's
        # `bundler.lockfile` discovery returned nothing (no lockfile to read).
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

        # ADR-93 WD3 — the standalone residual. A bare `gem install rigortype` has no `rbs-inline` library,
        # so the spec's "annotations are official type sources whenever present" cannot be satisfied: the
        # annotated code reads `Dynamic[top]`. When the library is absent AND the project actually carries
        # annotation-shaped comments, emit one `:info` routing the user to install it. Rigor never bundles it
        # (ADR-0 zero-dep). Suppressed whenever the library resolves (auto-wire or an explicit `plugins:`
        # entry then handles it — including the deliberate `enabled: false` opt-out, which resolves and so is
        # never nagged) or an `rbs-inline` plugin is already active for another reason.
        def rbs_inline_annotation_hint_diagnostics(expansion)
          return [] if Configuration.rbs_inline_library_resolvable?
          return [] if rbs_inline_plugin_active?

          first = expansion.fetch(:files).find { |path| file_carries_inline_annotation?(path) }
          return [] unless first

          [build_rbs_inline_unsynthesized_diagnostic(first)]
        end

        def rbs_inline_plugin_active?
          plugin_registry.plugins.any? { |plugin| plugin.manifest.id == "rbs-inline" }
        end

        # A deliberately coarse routing scan — NOT the upstream annotation grammar, which is exactly what is
        # unavailable here (that is the whole condition). It keys on the `# @rbs` block form and on a `#:`
        # comment immediately followed by the start of an RBS type (`(`, `[`, `{`, `?`, a `Constant`, or an
        # RBS lowercase base type), and never on an RDoc directive (`#:nodoc:` and friends read as a bare
        # lowercase word closed by a colon), so a project with no real annotations stays silent. Reads the
        # file directly (the analysis buffer is not threaded here) and early-exits on the first hit; this runs
        # at most once per run and only in the library-absent standalone case, so the extra read is bounded.
        INLINE_ANNOTATION_SHAPE = /
          (?:^|\s)\#\s*@rbs\b
          |
          (?:^|\s)\#:[ \t]*(?:[\[({?A-Z]|(?:bool|void|nil|untyped|top|bot|self|instance|class)\b)
        /x
        private_constant :INLINE_ANNOTATION_SHAPE

        def file_carries_inline_annotation?(path)
          File.foreach(path) do |line|
            return true if INLINE_ANNOTATION_SHAPE.match?(line)
          end
          false
        rescue StandardError
          false
        end

        def build_rbs_inline_unsynthesized_diagnostic(sample_path)
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "Inline rbs-inline annotations (`# @rbs …`, `#: <type>`) are present in your project " \
                     "(e.g. #{relative_signature_path(sample_path)}), but the `rbs-inline` library is not " \
                     "installed, so Rigor cannot read them and the annotated code stays `Dynamic[top]` — " \
                     "this run is quieter than your annotations intend, not cleaner. Install the " \
                     "`rbs-inline` gem (its dependency closure, `prism` + `rbs`, already ships with Rigor) " \
                     "and Rigor honours the annotations automatically (ADR-93); it is not bundled, keeping " \
                     "the core zero-dep (ADR-0).",
            severity: :info,
            rule: "rbs.coverage.inline-annotations-unsynthesized",
            source_family: :builtin
          )
        end

        # Robustness uplift companion (ADR-5) — when the project's `signature_paths:` RBS declared
        # qualified names without their enclosing namespace, `RbsLoader` synthesizes the missing `module`s
        # so the otherwise-inert signatures resolve. Surface a single `:info` diagnostic naming them so the
        # user knows their sig set is malformed (`rbs validate` rejects it) and can fix it at the source.
        # Authored `:info`: the analysis already succeeded; this is advisory, never a gate. Empty for a
        # well-formed sig set.
        # An unparseable or declaration-colliding `.rbs` under `signature_paths:` is QUARANTINED so the
        # rest of the env survives (PR #50; issue #777 extends this to class-vs-module / constant
        # collisions against bundled RBS), which means the types it declares are silently absent — calls
        # into them read `Dynamic[top]`, and the run gets *quieter*, not louder. The stderr banner alone
        # never reached CI:
        # it is not a diagnostic, so it is absent from `--format json` / SARIF / GitHub annotations / the LSP
        # and cannot move the exit code. This puts it in the diagnostic stream where every channel sees it.
        #
        # Authored `:warning`, not `:error`: an existing green build must not turn red on upgrade, and the
        # `rbs` gem's own parser moves across versions (ADR-79 keeps Rigor faithful to the project's `rbs`,
        # so a version bump CAN newly reject a file that used to parse). Rejecting a broken sig set outright
        # is a *new required discipline* — ADR-50 WD3 routes those through the bleeding-edge overlay, where
        # the `reject-unparseable-signatures` feature promotes this rule to `:error` for anyone who opts in
        # (and by default at the next major).
        def rbs_quarantined_signature_diagnostics
          quarantined = quarantined_signatures_snapshot
          return [] if quarantined.empty?

          [build_rbs_quarantined_signature_diagnostic(quarantined)]
        end

        # The twin of {#rbs_quarantined_signature_diagnostics}, one tier louder in consequence. Quarantine
        # drops ONE unparseable file and keeps the rest of the env; a total build failure — typically a
        # `signature_paths:` entry redeclaring a constant/class Rigor's bundled RBS already ships, which raises
        # `RBS::DuplicatedDeclarationError` at resolve — collapses the WHOLE env to nil, so every type-of query
        # degrades to `Dynamic[top]` and most rules stop firing: the run comes back EMPTY, which reads as clean.
        # The stderr banner ({RbsLoader#warn_about_env_build_failure_once}) is not a diagnostic, so it never
        # reached `--format json` / SARIF / CI annotations / the LSP; this puts it in the diagnostic stream so
        # every channel sees it, and names the conflicting signature files off the raised error's `#decls`.
        #
        # Authored `:warning`, not `:error`, for the same reason as its quarantine twin: the conflict is
        # *typically* between the user's `sig/` and Rigor's OWN bundled RBS, so an `:error` default would let a
        # Rigor release turn a green build red with zero user change (AGENTS.md § FP discipline). The
        # `reject-unparseable-signatures` bleeding-edge feature promotes it to `:error` for anyone who opts in
        # (and by default at the next major).
        def rbs_environment_build_failed_diagnostics
          failure = env_build_failure_snapshot
          return [] if failure.nil?

          [build_rbs_environment_build_failed_diagnostic(failure)]
        end

        # Issue #696 — the third rung of the same ladder, between its two neighbours by consequence: a
        # QUARANTINED file removes what one FILE declared, this removes what one CLASS declared, an
        # ENV-BUILD failure removes everything. `RBS::DefinitionBuilder` raising for a class (typically
        # `DuplicatedMethodDefinitionError`: two signature sources declaring the same method, e.g. a project
        # `sig/` carrying a vendored COPY of a bundled plugin's `.rbs`) leaves the class KNOWN but with no
        # method surface, so every call on it — real methods and typos alike — reads `Dynamic[top]`. When
        # the collision is on a class others inherit, the whole bundled type universe goes with it: the
        # observed shape is thousands of stderr warnings, ZERO diagnostics, and exit 0.
        #
        # Not "drop the class to genuinely-unknown" instead. That also removes diagnostics, so it is not
        # louder; it changes `Dynamic[top]` semantics for every rule that consults `class_known?`; and
        # `class_known?` reads {Environment::RbsLoader#known_class_names_set}, a different table from the
        # definition builder, so it would need a new "known but unbuildable" state regardless. The failure
        # is made REPORTABLE; the class is not made invisible.
        #
        # Authored `:warning`, not `:error`, for the same reason as both neighbours: the collision is
        # typically between the user's `sig/` and Rigor's OWN bundled RBS, so an `:error` default would let
        # a Rigor release turn a green build red with no user change (ADR-5 / AGENTS.md § FP discipline).
        # The `reject-unparseable-signatures` bleeding-edge feature promotes it to `:error`.
        def rbs_definition_build_failed_diagnostics
          failures = definition_build_failures_snapshot
          return [] if failures.nil? || failures.empty?

          [build_rbs_definition_build_failed_diagnostic(failures)]
        end

        # Issue #784 — the fourth rung, narrowest consequence: one of the two builds behind
        # `Environment#hkt_registry` raised instead of building. The `:scan` stage is the implicit HKT scan
        # over RBS `type` aliases (ADR-20 WD2's `%a{rigor:v1:hkt_register / hkt_define}` overlay AND any
        # recursive `type` alias in the project's own `.rbs` or an installed `rbs collection`); analysis
        # proceeds over the PRE-scan registry — bundled builtins (`json::value`, …) plus the plugin overlay
        # — so a `type` alias that would have registered as a type constructor reads its bound
        # (`Dynamic[top]`) instead. The `:overlay` stage (#791) is the plugin-manifest aggregation, which
        # sat ABOVE the seam until the run-owned demands made a raise there abort the run; it degrades one
        # step further in and one step narrower — the plugin entries are dropped, the `.rbs` scan still
        # runs. Either way everything else this run reports is unaffected: no class loses its method
        # surface, no signature file is skipped, the environment builds. That is why this sits LAST on the
        # ladder, after its two `rbs.coverage.*` siblings above.
        def rbs_hkt_scan_failed_diagnostics
          failure = hkt_scan_failure_snapshot
          return [] if failure.nil?

          [build_rbs_hkt_scan_failed_diagnostic(failure)]
        end

        def rbs_synthesized_namespace_diagnostics
          synthesized = synthesized_namespaces_snapshot
          return [] if synthesized.nil? || synthesized.empty?

          [build_rbs_synthesized_namespace_diagnostic(synthesized)]
        end

        # Issue #610 — the outcome that AVOIDED `rbs.coverage.definition-build-failed`'s rung: a signature
        # file a loaded plugin contributes re-declared a class another loaded source (typically an `rbs
        # collection install`) already declares at a DIFFERENT generic arity, so the plugin's file stood
        # down rather than fail the class's definition build. One `:info` per file: the user is told what
        # typing they are not getting and why, and — unlike the quarantine row this file used to be
        # misreported as — is not sent to remove a declaration the plugin owns.
        def rbs_plugin_signature_stood_down_diagnostics
          standdowns = signature_standdowns_snapshot
          return [] if standdowns.nil? || standdowns.empty?

          standdowns.map { |entry| build_rbs_plugin_signature_stood_down_diagnostic(entry) }
        end

        # The two `:info` notices that close the `rbs.coverage.*` ladder, in this order: the namespace
        # synthesis first, then the stand-down (#610) — the outcome that AVOIDED a definition-build failure
        # and so the quietest row on it. One method so the runner's assembly reads them as one slot.
        def rbs_coverage_notice_diagnostics
          rbs_synthesized_namespace_diagnostics + rbs_plugin_signature_stood_down_diagnostics
        end

        # Maps the per-run `rigor:v1:conforms-to` scan results into diagnostics (spec: `rbs-extended.md` §
        # "Explicit conformance directive"). A class that declares `conforms-to _Interface` but is missing
        # a required interface method surfaces as `rbs_extended.unsatisfied-conformance`; an unresolvable
        # interface name surfaces as `dynamic.rbs-extended.unresolved` `:info` (the same fail-soft channel
        # the other directive parsers use). Empty for a project with no directive, a well-formed
        # conformance, or a non-sequential pool run (the snapshot mirrors `synthesized_namespaces`).
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

        def build_rbs_quarantined_signature_diagnostic(quarantined)
          sample_size = 5
          sample = quarantined.first(sample_size).map { |path, _first_line| relative_signature_path(path) }
          suffix = quarantined.size > sample_size ? ", and #{quarantined.size - sample_size} more" : ""
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "#{quarantined.size} RBS file(s) under `signature_paths:` were SKIPPED " \
                     "(unparseable, or duplicated against bundled RBS): #{sample.join(', ')}#{suffix}. " \
                     "The rest of your RBS environment still loaded, but the types those files declare " \
                     "are absent — calls into them read `Dynamic[top]`, so this run is quieter than it " \
                     "should be, not cleaner. Fix the parse error(s) or remove the conflicting " \
                     "declaration(s) (`rbs validate`) to restore that coverage.",
            severity: :warning,
            rule: "rbs.coverage.quarantined-signature",
            source_family: :builtin
          )
        end

        def build_rbs_environment_build_failed_diagnostic(failure)
          error_class, first_line, buffers = failure
          sample_size = 5
          files = Array(buffers).map { |name| relative_signature_path(name.to_s) }
          sample = files.first(sample_size)
          suffix = files.size > sample_size ? ", and #{files.size - sample_size} more" : ""
          conflicts = sample.empty? ? "" : " Conflicting signature file(s): #{sample.join(', ')}#{suffix}."
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "The RBS environment failed to build (#{error_class}): #{first_line}.#{conflicts} " \
                     "A `signature_paths:` entry typically redeclares a constant or class that Rigor's " \
                     "bundled RBS already ships, which collapses the WHOLE environment to nil — every " \
                     "type-of query then reads `Dynamic[top]` and most diagnostics stop firing, so this " \
                     "run is EMPTY rather than clean. Remove the conflicting declaration from your `sig/` " \
                     "(`rbs validate`) to restore type coverage.",
            severity: :warning,
            rule: "rbs.coverage.environment-build-failed",
            source_family: :builtin
          )
        end

        # Issue #696. One diagnostic per RUN, not per class: a collision on a widely-inherited class fails
        # every descendant, and 2,709 rows saying the same thing about one `.rbs` line is noise, not
        # visibility.
        #
        # The failed-class list alone is not actionable, and that is what the "First failure" clause is for.
        # A duplicate on `::Object#blank?` fails `String`, `Integer`, `Array` and 1,333 more — every name in
        # that list is a DESCENDANT, and none of them is where the fix goes. The member comes off the error
        # object rather than out of its message ({RbsLoader#definition_build_member}), so it names the
        # culprit and reads the same on a cache hit, where every `RBS::Location` has been dumped to a
        # sentinel. The error class is attributed to that first failure explicitly rather than to all of
        # them: the per-class memo keeps only the first reason, and one run can mix error classes.
        def build_rbs_definition_build_failed_diagnostic(failures)
          sample_size = 5
          files = failures.flat_map { |failure| Array(failure[3]) }.uniq.map { |name| relative_signature_path(name) }
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "#{failures.size} RBS class definition(s) failed to build: " \
                     "#{sampled(failures.map(&:first), sample_size)}." \
                     "#{first_failure_clause(failures.first)}#{conflicting_files_clause(files, sample_size)} " \
                     "Rigor still treats each class as KNOWN, so calls into it — real methods and typos " \
                     "alike — silently read `Dynamic[top]` instead of resolving, and this run is quieter " \
                     "than it should be rather than cleaner. #{definition_build_advice(failures.first)}",
            severity: :warning,
            rule: "rbs.coverage.definition-build-failed",
            source_family: :builtin
          )
        end

        # The closing advice follows the FIRST failure's error class: `GenericParameterMismatchError` is two
        # declarations of one CLASS at different generic arity (#610), and "remove the duplicate member"
        # sends its reader after a member that does not exist.
        def definition_build_advice(failure)
          _, error_class, = failure
          if error_class.to_s.end_with?("GenericParameterMismatchError")
            "Two signature sources declare the class with a different number of type parameters; make " \
              "the declarations agree (`rbs validate`) to restore type coverage."
          else
            "Two signature sources declare the same member; remove the duplicate declaration " \
              "(`rbs validate`) to restore type coverage."
          end
        end

        # `[class_name, error_class, member, buffers]`. The member is nil for the error classes that carry no
        # name at all (`RecursiveAncestorError`), and the clause then names the error class alone rather than
        # inventing a member.
        def first_failure_clause(failure)
          _, error_class, member, = failure
          return " First failure: #{error_class}." if member.nil? || member.empty?

          " First failure: #{error_class} on `#{member}`."
        end

        # Identical on a cache HIT: the ADR-54 env cache drops location POSITIONS but keeps each buffer's
        # NAME, so a warm run names the same files a cold one does. Where a name is absent anyway, the
        # reconstructed {RbsLoader::CACHED_LOCATION_BUFFER_NAME} sentinel is filtered out and the clause is
        # omitted, rather than naming `<cached>` as if it were a path.
        def conflicting_files_clause(files, sample_size)
          return "" if files.empty?

          " Conflicting signature file(s): #{sampled(files, sample_size)}."
        end

        # "a, b, c, and N more" — the sampling shape every `rbs.coverage.*` message above uses.
        def sampled(names, sample_size)
          sample = names.first(sample_size)
          suffix = names.size > sample_size ? ", and #{names.size - sample_size} more" : ""
          "#{sample.join(', ')}#{suffix}"
        end

        # Issue #784 — one `:error` row per run, unlike its two `:warning` `rbs.coverage.*` siblings above.
        # Those two are typically a collision between the user's OWN `sig/` and Rigor's bundled RBS, so an
        # `:error` default would let a Rigor release turn a green project red with zero user change (ADR-5
        # / AGENTS.md § FP discipline) — the reason both stay `:warning` by default. This row has no such
        # neighbour: post-#783 the scan itself raising is an ANALYZER defect, never something a user's
        # `sig/` could trigger on its own, so there is no green project this could newly redden. And the
        # run was already non-zero before this row existed — issue #784's seam is what stopped the raise
        # from reaching every file as N identical `internal analyzer error` rows in the first place, and
        # THAT per-file rescue is what `Result#success?` was already reading as a failure; this row only
        # makes the reason legible.
        #
        # One row per RUN, not per file: the scan is one build over the whole `signature_paths:` overlay
        # (memoised — see {Environment#hkt_registry}), so every file that would have demanded it hit the
        # exact same failure, and a row per file would say the same thing N times.
        #
        # `:rbs_build` (via {CrashSignature::RBS_BUILD_FAILURE_RULES}), not `:check_rule`: the analysis ran
        # to completion over a DEGRADED type universe — every rule still fired, unlike `:check_rule`'s
        # whole-file replacement — so a consumer gating on {CrashSignature.discards_file_analysis?} must
        # keep reading this run's diagnostics rather than refuse it as a crash.
        def build_rbs_hkt_scan_failed_diagnostic(failure)
          error_class, first_line, frame, stage = failure
          relative_frame = CrashSignature.relativize_frame(frame)
          frame_clause = relative_frame ? " at #{relative_frame}" : ""
          raised = "(#{error_class}): #{first_line}#{frame_clause}."
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: stage == :overlay ? hkt_overlay_failed_message(raised) : hkt_scan_failed_message(raised),
            severity: :error,
            rule: "rbs.coverage.hkt-scan-failed",
            source_family: :builtin
          )
        end

        def hkt_scan_failed_message(raised)
          "The implicit HKT scan over RBS `type` aliases raised #{raised} Rigor fell back to the bundled " \
            "and plugin HKT registrations, so a recursive `type` alias in your `.rbs` or an installed " \
            "`rbs collection` no longer registers as a type constructor and reads its bound " \
            "(`Dynamic[top]`) instead — this run is quieter than it should be, not cleaner. " \
            "This is an analyzer defect, not a problem with your signatures; please report it " \
            "with the message above."
        end

        # Issue #791 — the overlay stage of the same build, worded for the plugin it came from. The scan
        # wording would send a user to their `.rbs` for a defect that is not there: what failed is the
        # aggregation of the loaded plugins' manifest-declared HKT entries, and the message names the
        # plugin whenever the raise was attributable to one (`Plugin::Registry#hkt_overlay_registry` puts
        # the id in the message it re-raises). The degradation is narrower than the scan's, so the fallback
        # sentence differs too: only the plugin entries are missing, and the user's own `.rbs` scan still
        # ran on top of the bundled registrations.
        def hkt_overlay_failed_message(raised)
          "Building the plugin HKT overlay raised #{raised} Rigor skipped every plugin-declared HKT " \
            "registration and analysed with the bundled ones plus your own `.rbs` overlay, so a type " \
            "constructor a plugin declares reads its bound (`Dynamic[top]`) instead — this run is " \
            "quieter than it should be, not cleaner. This is a defect in the named plugin or in Rigor, " \
            "not a problem with your signatures; report it with the message above, or remove the plugin " \
            "from `plugins:` to analyse without it."
        end

        # The absolute path is what the loader records; the user thinks in project-relative terms.
        def relative_signature_path(path)
          root = "#{Dir.pwd}#{File::SEPARATOR}"
          path.start_with?(root) ? path.delete_prefix(root) : path
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

        def build_rbs_plugin_signature_stood_down_diagnostic(entry)
          path, class_name, existing_arity, incoming_arity, existing_file = entry
          displaced_by = displacing_source_phrase(existing_file)
          Diagnostic.new(
            path: ".rigor.yml",
            line: 1,
            column: 1,
            message: "`#{relative_signature_path(path.to_s)}` (a signature file a plugin contributes) declares " \
                     "`#{class_name.to_s.delete_prefix('::')}` with #{type_parameter_phrase(incoming_arity)}, " \
                     "but #{displaced_by} already declares it with #{type_parameter_phrase(existing_arity)}. " \
                     "Two declarations of one class at different generic arity fail its definition build, so " \
                     "the plugin's file stood down: calls into the class resolve against the other " \
                     "declaration, and the plugin's element typing for it is unavailable while both are " \
                     "loaded. Expected when a bundled plugin and an `rbs collection install` both declare " \
                     "the class; nothing to fix unless you want the plugin's typing back, which needs the " \
                     "other source to stop declaring the class.",
            severity: :info,
            rule: "rbs.coverage.plugin-signature-stood-down",
            source_family: :builtin
          )
        end

        def displacing_source_phrase(existing_file)
          return "another loaded signature source" if existing_file.nil?

          "`#{relative_signature_path(existing_file.to_s)}`"
        end

        def type_parameter_phrase(arity)
          case arity
          when nil, 0 then "no type parameters"
          when 1 then "1 type parameter"
          else "#{arity} type parameters"
          end
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

        # ADR-13 slice 3b — drains the per-run {RbsExtended::Reporter} into one diagnostic per accumulated
        # event:
        #
        # - `dynamic.rbs-extended.unresolved` for every annotation payload the parser could not turn into a
        #   {Rigor::Type}. Surfaces typos and references to plugin-supplied names the project did not
        #   enable.
        # - `dynamic.shape.lossy-projection` for every shape-projection type function (`pick_of`, …) applied
        #   to a carrier that loses precision (anything other than `HashShape` / `Tuple`).
        # - `dynamic.rbs-extended.hkt-directive-invalid` for every malformed ADR-20 `rigor:v1:hkt_register` /
        #   `rigor:v1:hkt_define` the directive parser declined (issue #785).
        #
        # All three are authored `:info`; the severity profile re-stamps them per project taste. Every stream
        # carries its `(path, line, column)` already flattened off the annotation's `RBS::Location`, because
        # all three cross the pool drain channel (see {RbsExtended::Reporter}); an entry with no position
        # falls back to `.rigor.yml`-style file-level attribution.
        def rbs_extended_reporter_diagnostics
          return [] if @rbs_extended_reporter.empty?

          unresolved = @rbs_extended_reporter.unresolved_payloads.map do |entry|
            build_positioned_reporter_diagnostic(
              entry,
              rule: "dynamic.rbs-extended.unresolved",
              message: "`RBS::Extended` directive payload could not be resolved: " \
                       "#{entry.payload.inspect}. Check for typos or enable a plugin " \
                       "that contributes the referenced type vocabulary."
            )
          end

          lossy = @rbs_extended_reporter.lossy_projections.map do |entry|
            build_positioned_reporter_diagnostic(
              entry,
              rule: "dynamic.shape.lossy-projection",
              message: "Shape projection `#{entry.head}` applied to a carrier without a " \
                       "literal shape; the projection degrades to the input type. Author " \
                       "a `HashShape` / `Tuple` carrier or accept the unchanged result."
            )
          end

          unresolved + lossy + hkt_directive_diagnostics + deprecated_form_diagnostics
        end

        # ADR-109 WD3 — one row per annotation still written in a spelling the grammar accepts but no
        # longer displays. The row names the replacement because the deprecation window exists for exactly
        # this edit, and it stays `:info`: the annotation resolved, the run is as green as it was.
        def deprecated_form_diagnostics
          @rbs_extended_reporter.deprecated_forms.map do |entry|
            build_positioned_reporter_diagnostic(
              entry,
              rule: "dynamic.rbs-extended.deprecated-form",
              message: "`#{entry.payload}` is a deprecated spelling; write `#{entry.replacement}`. The " \
                       "angle-bracket integer range is accepted for one deprecation window and removed " \
                       "at the next compatibility break (ADR-109)."
            )
          end
        end

        # Issue #785 — one row per declined HKT directive. The consequence sentence is the point: the parser
        # is fail-soft, so nothing else in the run tells the author that the constructor they registered is
        # not there and that every `App[…]` naming it silently reads its bound.
        def hkt_directive_diagnostics
          @rbs_extended_reporter.hkt_directive_errors.map do |entry|
            build_positioned_reporter_diagnostic(
              entry,
              rule: "dynamic.rbs-extended.hkt-directive-invalid",
              message: "`RBS::Extended` HKT directive was declined: #{entry.message}. The type " \
                       "constructor stays unregistered, so an `App[...]` carrier naming it reads " \
                       "its bound (`Dynamic[top]`) instead of the type function."
            )
          end
        end

        # ADR-32 WD6 — drains the per-run {Plugin::SourceRbsSynthesisReporter} into
        # `source-rbs-synthesis-failed` `:info` diagnostics. Each entry names the plugin that owns the
        # synthesizer, the source file the rbs-inline parser couldn't process, and the upstream error
        # message. The synthesizer-emitting plugin (currently only `rigor-rbs-inline`) treats a parse
        # failure as a no-contribution event so analysis continues; this stream surfaces the failure so the
        # user can see which files contributed nothing and why.
        #
        # Severity profile re-stamps the rule per project taste.
        def source_rbs_synthesis_diagnostics
          return [] if @source_rbs_synthesis_reporter.empty?

          @source_rbs_synthesis_reporter.entries.map do |entry|
            entry.kind == :not_honoured ? not_honoured_diagnostic(entry) : synthesis_failed_diagnostic(entry)
          end
        end

        def synthesis_failed_diagnostic(entry)
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

        # ADR-32 WD12 — the synthesis SUCCEEDED; one annotation inside it was parsed and then contributed
        # nothing. Distinct from the failure above in the only way that matters to the reader: the rest of
        # the file's annotations ARE in effect, so the advice is to fix one comment, not to distrust the file.
        def not_honoured_diagnostic(entry)
          Diagnostic.new(
            path: entry.path, line: 1, column: 1,
            message: "plugin `#{entry.plugin_id}` parsed an inline-RBS annotation in this file but did " \
                     "not honour it: #{entry.message} The file's other annotations are unaffected.",
            severity: :info,
            rule: "source-rbs-annotation-not-honoured",
            source_family: :builtin
          )
        end

        # ADR-10 slice 5c — drains the per-run {DependencySourceInference::BoundaryCrossReporter} into
        # `dynamic.dependency-source.boundary-cross` `:info` diagnostics. Each event flags a call site
        # where RBS dispatch produced a concrete answer AND a `mode: :full` opt-in gem's source catalog
        # ALSO contains an entry for the same `(class_name, method_name)` — i.e., both contracts have an
        # opinion. RBS still wins on the dispatch result; the diagnostic is purely advisory so the user can
        # verify the two contracts haven't drifted.
        #
        # Severity profile re-stamps the rule per project taste. The diagnostic carries no `path` / `line`
        # / `column` because the crossing is per-method-per-gem, not per-call-site — the diagnostic anchors
        # at `.rigor.yml` like the other `dependency-source.*` diagnostics that report on opt-in
        # configuration.
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

        # Issue #959 — surfaces the {Plugin::IoBoundary} refusal history each loaded plugin accumulated over
        # the whole run (prepare AND every per-file call: `#io_boundary` is memoised per plugin instance, so
        # one boundary sees both). `TrustPolicy#allow_read?` stays `File.expand_path`-only per ADR-2 — a
        # project rooted under a symlink (macOS' `/tmp` → `/private/tmp` is the common case) can have every
        # plugin read fall outside its own read roots with nothing said about it. One `:info` row per plugin
        # that hit this, never one per path, naming the count and the first path so the row stays legible on
        # a plugin that walked a whole out-of-scope subtree.
        #
        # Positioned here, in `#pre_file_diagnostics`'s post-analysis sibling list (called from
        # `Runner#assemble_run_diagnostics`, which only runs on an ADR-45 cache MISS): the refusal history is
        # a function of the plugin code and the resolved paths for THIS configuration, so it is deterministic
        # across runs of the same inputs and the row that lands in a miss's cached diagnostics blob is the
        # row a later warm HIT correctly re-serves — the same regeneration contract every other stream
        # aggregated in `#pre_file_diagnostics` / `#assemble_run_diagnostics` already relies on (see
        # `docs/type-specification/diagnostic-policy.md` § "Run-level rows and the record-and-validate
        # cache"). It is also never routed through `IncrementalSession`'s per-file cache (`#788`): that cache
        # holds only `Runner#per_file_diagnostics`, and this row is not part of that stream.
        #
        # Scope: `plugin_registry` here is the coordinator-side registry, which only actually RUNS `#prepare`
        # / per-file analysis in sequential mode (`--workers` unset, the default) — a pooled run (`--workers
        # N`) prepares and analyses on per-worker `WorkerSession` registries this reader never sees, so a
        # refusal confined to a pooled worker's slice is not reported. Left out deliberately: draining it
        # needs a fourth marshalled channel beside `drain_reporters` / `drain_dependencies` / `drain_effects`
        # in `Runner::PoolCoordinator`, and the default (unpooled) path already covers the reported bug.
        def plugin_trust_refusal_diagnostics
          return [] if plugin_registry.empty?

          plugin_registry.plugins.filter_map { |plugin| plugin_trust_refusal_diagnostic(plugin) }
        end

        def plugin_trust_refusal_diagnostic(plugin)
          summary = plugin.io_boundary.refusal_summary
          return nil if summary.nil?

          plugin_id = plugin.manifest.id
          Diagnostic.new(
            path: ".rigor.yml", line: 1, column: 1,
            message: "plugin #{plugin_id.inspect} had #{summary[:count]} read(s) refused by the trust " \
                     "policy; first refused path: #{summary[:first_path].inspect}, outside read root " \
                     "#{summary[:nearest_root].inspect}. Spell the path the way that read root spells it " \
                     "(a symlink alias such as macOS' /tmp does not match its real path), or add a " \
                     "`plugins_io.allowed_paths:` entry in .rigor.yml covering the path.",
            severity: :info,
            rule: "plugin_trust.read-refused",
            source_family: :builtin
          )
        rescue StandardError
          nil
        end

        def build_reporter_diagnostic(source_location, rule:, message:)
          path, line, column = location_fields(source_location)
          Diagnostic.new(
            path: path, line: line, column: column,
            message: message, severity: :info, rule: rule, source_family: :builtin
          )
        end

        # The {RbsExtended::Reporter} form of the builder above: its three streams carry the position as
        # `(path, line, column)` primitives rather than as the `RBS::Location` a conformance record holds,
        # because they cross the pool drain channel (#785, #805). A missing component falls back exactly as
        # {#location_fields} does for a missing location.
        def build_positioned_reporter_diagnostic(entry, rule:, message:)
          path = entry.path.to_s
          Diagnostic.new(
            path: path.empty? ? ".rigor.yml" : path,
            line: entry.line || 1,
            column: entry.column || 1,
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

        # ADR-8 § "Severity profile" — re-stamps each diagnostic's severity from the configured profile +
        # per-rule overrides, dropping any that resolve to `:off`. Delegates to the shared {SeverityStamp} so
        # the ADR-87 WD4 boot-slimming hit path applies the identical final filter.
        def apply_severity_profile(diagnostics)
          SeverityStamp.apply(diagnostics, @configuration)
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

        def quarantined_signatures_snapshot
          @quarantined_signatures_snapshot_reader.call
        end

        def signature_standdowns_snapshot
          @signature_standdowns_snapshot_reader.call
        end

        def env_build_failure_snapshot
          @env_build_failure_snapshot_reader.call
        end

        def definition_build_failures_snapshot
          @definition_build_failures_snapshot_reader.call
        end

        def hkt_scan_failure_snapshot
          @hkt_scan_failure_snapshot_reader.call
        end

        def conformance_results_snapshot
          @conformance_results_snapshot_reader.call
        end
      end
    end
  end
end
