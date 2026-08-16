# frozen_string_literal: true

require "prism"

require_relative "../diagnostic"
require_relative "../check_rules"
require_relative "../../effects/envelope_check"
require_relative "../../effects/registry"
require_relative "../../rbs_extended/envelope_scanner"

module Rigor
  module Analysis
    class Runner
      # `effect.envelope-exceeded`, end to end (ADR-103 WD8 / WD12; #383).
      #
      # Three steps, and the order is the cost model:
      #
      # 1. **Read the envelopes** off the project's own RBS ({RbsExtended::EnvelopeScanner}). A project
      #    with `effects:` but no envelope pays this walk and stops here.
      # 2. **Force cross-file discovery**, but only when step 1 found something — the diagnostic is
      #    positioned at the Ruby `def`, and the discovery tables are what map a method key to one.
      # 3. **Judge** ({Effects::EnvelopeCheck}) and render, then run the findings through the ordinary
      #    suppression filter so `# rigor:disable effect.envelope-exceeded` on the `def` line and
      #    `disable:` in `.rigor.yml` work exactly as they do for a per-file rule.
      #
      # **Why this is not part of the cached run assembly.** ADR-103 WD12 says envelope diagnostics are
      # recomputed every run from the (possibly cached) summaries and never stored. The `effects:` block
      # is deliberately absent from the diagnostics cache identity — that absence is what lets a project
      # turn collection on without invalidating its check — so a finding baked into that entry would
      # survive an `effects.check: false` edit. The pass therefore runs OUTSIDE
      # `Runner#compute_run_diagnostics`, over whatever table the run ended up with, warm or cold.
      class EffectEnvelopePass
        NO_DIAGNOSTICS = [].freeze
        private_constant :NO_DIAGNOSTICS

        RULE = CheckRules::RULE_EFFECT_ENVELOPE_EXCEEDED

        # Where `Environment.for_project` looks when no `signature_paths:` is configured. Spelled again
        # here rather than required, because the constant is private to {Rigor::Environment} and a pass
        # over the loaded env has no business reaching into its builder.
        DEFAULT_SIGNATURE_ROOTS = ["sig"].freeze
        private_constant :DEFAULT_SIGNATURE_ROOTS

        # @param configuration [Rigor::Configuration]
        # @param rbs_loader [Rigor::Environment::RbsLoader, nil] the run's loader; nil disables the pass.
        # @param effect_table [Rigor::Effects::EffectTable] the propagated graph.
        # @param discovery [#call] forces and returns the cross-file discovery tables as
        #   `[def_sources, singleton_def_sources, class_sources]`. Called only when an envelope exists.
        # @param sources [Hash{String => String}] in-memory sources, for the buffer-backed run path.
        def initialize(configuration:, rbs_loader:, effect_table:, discovery:, sources: nil)
          @configuration = configuration
          @rbs_loader = rbs_loader
          @effect_table = effect_table
          @discovery = discovery
          @sources = sources || {}
        end

        # @return [Array<Diagnostic>] one per (method, exceeding label), suppression already applied.
        def diagnostics
          return NO_DIAGNOSTICS unless @configuration.effects_check?
          return NO_DIAGNOSTICS if @rbs_loader.nil? || @effect_table.empty?

          scan = RbsExtended::EnvelopeScanner.scan(
            sources: signature_sources, registry: Effects::Registry.default
          )
          return NO_DIAGNOSTICS if scan.empty?

          findings = judge(scan)
          return NO_DIAGNOSTICS if findings.empty?

          suppress(findings.map { |finding| build_diagnostic(finding) })
        rescue StandardError
          # Fail-soft, like every other effects surface: an envelope Rigor cannot read must not fail a
          # check that would otherwise pass.
          NO_DIAGNOSTICS
        end

        private

        def judge(scan)
          def_sources, singleton_def_sources, class_sources = @discovery.call
          Effects::EnvelopeCheck.run(
            table: @effect_table,
            method_envelopes: scan.method_envelopes, class_envelopes: scan.class_envelopes,
            def_sources: def_sources || {}, singleton_def_sources: singleton_def_sources || {},
            class_sources: class_sources || {}
          )
        end

        # Everything an envelope may be written in, as `[buffer name, source]` pairs: the project's own
        # `signature_paths:` tree (or the `sig/` default `Environment.for_project` falls back to), plus the
        # loader's virtual entries — which is how rbs-inline's `# @rbs %a{…}` comments and a plugin's
        # `source_rbs` synthesis arrive. Gem-shipped and bundled RBS is deliberately absent: ADR-103 WD6
        # makes project-authored envelopes the checked stratum, so a `%a{pure}` in rbs core cannot bound a
        # project method that happens to share its key.
        def signature_sources
          files = signature_roots.flat_map { |root| Dir.glob(File.join(root.to_s, "**", "*.rbs")).sort }
          sources = files.filter_map do |path|
            [path, File.read(path)]
          rescue StandardError
            nil
          end
          sources + Array(@rbs_loader.virtual_rbs).map { |name, content| [name.to_s, content.to_s] }
        end

        def signature_roots
          paths = @configuration.signature_paths
          paths.nil? || paths.empty? ? DEFAULT_SIGNATURE_ROOTS : paths
        end

        def build_diagnostic(finding)
          Diagnostic.new(
            path: finding.path || ".rigor.yml",
            line: finding.line,
            column: 1,
            message: message_for(finding),
            severity: :warning,
            rule: RULE,
            source_family: :builtin,
            method_name: method_name_of(finding.key)
          )
        end

        # The shape a reviewer can act on without re-running anything: what the method does, the shortest
        # route to whatever proves it, the author's own spelling of the bound quoted back, and where that
        # bound was written.
        def message_for(finding)
          "Method #{finding.key} performs #{finding.label}#{explanation(finding)}, but is declared " \
            "#{finding.envelope.spelling}#{declared_at(finding.envelope)}, so #{finding.label} exceeds " \
            "the envelope."
        end

        def explanation(finding)
          hops = Array(finding.chain)[1..] || []
          parts = [finding.origin, ("via #{hops.join(' → ')}" unless hops.empty?)].compact
          parts.empty? ? "" : " (#{parts.join(' ')})"
        end

        def declared_at(envelope)
          owner = envelope.source == :class_annotation ? " on #{envelope.owner_key.split(/[#.]/).first}" : ""
          where = envelope.location ? " at #{envelope.location}" : ""
          "#{owner}#{where}"
        end

        def method_name_of(key)
          index = key.index("#") || key.index(".")
          index.nil? ? nil : key[(index + 1)..]
        end

        # The ordinary suppression pipeline, per file: `# rigor:disable` / `# rigor:disable-file` comments
        # from the Ruby file the diagnostic is positioned in, plus the project's `disable:` list. Reading
        # the comments costs one parse per file that actually carries a finding.
        def suppress(diagnostics)
          diagnostics.group_by(&:path).flat_map do |path, group|
            CheckRules.filter_suppressed(
              group, comments: comments_for(path), disabled_rules: @configuration.disabled_rules
            )
          end
        end

        def comments_for(path)
          source = @sources[path]
          result = source ? Prism.parse(source) : Prism.parse_file(path)
          result.comments
        rescue StandardError
          [].freeze
        end
      end
    end
  end
end
