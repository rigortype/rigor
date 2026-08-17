# frozen_string_literal: true

require "prism"

require_relative "../diagnostic"
require_relative "../check_rules"
require_relative "../../effects/config_envelopes"
require_relative "../../effects/envelope_check"
require_relative "../../effects/method_key"
require_relative "../../effects/registry"
require_relative "../../effects/signature_sources"
require_relative "../../effects/unknown_label_check"
require_relative "../../rbs_extended/envelope_scanner"

module Rigor
  module Analysis
    class Runner
      # `effect.envelope-exceeded` and `effect.unknown-label`, end to end (ADR-103 WD1 / WD8 / WD12;
      # #383 / #384).
      #
      # The two ride one gate and one walk on purpose. `effect.unknown-label` reports that an envelope
      # STOPPED bounding — the fail-open degradation an unrecognised label causes — so opting into
      # envelope enforcement is exactly what should turn it on, and reading it off any other pass
      # would mean walking the project's signatures twice.
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
        UNKNOWN_LABEL_RULE = CheckRules::RULE_EFFECT_UNKNOWN_LABEL

        # Where a diagnostic about a configuration value is positioned when the loader cannot say
        # which line the key was written on — the `rbs.coverage.quarantined-signature` precedent.
        CONFIG_PATH = ".rigor.yml"
        private_constant :CONFIG_PATH

        RUBY_EXTENSION = ".rb"
        private_constant :RUBY_EXTENSION

        # What a `.rigor.yml` label list stops doing once one of its members is unrecognised.
        TOLERATED_CONSEQUENCE = "the entry discharges nothing"
        private_constant :TOLERATED_CONSEQUENCE

        # An `envelopes[].effect` list degrades exactly as an annotation does: the whole tag reads ⊤.
        ENVELOPE_CONSEQUENCE = "the entry now bounds nothing"
        private_constant :ENVELOPE_CONSEQUENCE

        # An attribution's labels are a *claim*, so an unrecognised member costs meaning rather than a
        # bound: the labels are still attributed, and nothing in the vocabulary explains them.
        ATTRIBUTION_CONSEQUENCE = "the attributed label means nothing to the vocabulary"
        private_constant :ATTRIBUTION_CONSEQUENCE

        # `effects.labels:` is the one list whose whole point is to introduce a spelling, so a member of
        # it can only be unrecognised by being unregisterable — a root the loader dropped.
        LABELS_CONSEQUENCE = "the label is not registered"
        private_constant :LABELS_CONSEQUENCE

        # @param configuration [Rigor::Configuration]
        # @param rbs_loader [Rigor::Environment::RbsLoader, nil] the run's loader; nil disables the pass.
        # @param effect_table [Rigor::Effects::EffectTable] the propagated graph.
        # @param discovery [#call] forces and returns the cross-file discovery tables as
        #   `[def_sources, singleton_def_sources, class_sources]`. Called only when an envelope exists.
        # @param sources [Hash{String => String}] in-memory sources, for the buffer-backed run path.
        # @param unit_sources [Hash{String => Array<String>}] `Runner#effect_sources` — where each effect
        #   unit is defined, which is what an `effects.envelopes[].match:` path glob selects on. Its paths
        #   are relativised against the working directory, which is the project root for every run that
        #   reaches here (the same assumption `Snapshot.build` makes about `reach:`).
        # @param apply_tolerated [Boolean] false runs the judgment with an empty tolerated set
        #   (`--no-tolerated-effects`).
        def initialize(configuration:, rbs_loader:, effect_table:, discovery:, sources: nil,
                       unit_sources: nil, apply_tolerated: true)
          @configuration = configuration
          @rbs_loader = rbs_loader
          @effect_table = effect_table
          @discovery = discovery
          @sources = sources || {}
          @unit_sources = unit_sources || {}
          @apply_tolerated = apply_tolerated
        end

        # @return [Array<Diagnostic>] one per (method, exceeding label) plus one per unrecognised
        #   label, suppression already applied.
        def diagnostics
          return NO_DIAGNOSTICS unless @configuration.effects_check?

          produced = config_label_diagnostics + config_envelope_diagnostics + declaration_diagnostics
          return NO_DIAGNOSTICS if produced.empty?

          suppress(produced)
        rescue StandardError
          # Fail-soft, like every other effects surface: an envelope Rigor cannot read must not fail a
          # check that would otherwise pass.
          NO_DIAGNOSTICS
        end

        private

        # The envelopes, from both strata, and the judgment over them.
        #
        # The `.rbs` / rbs-inline walk is the expensive half and stays lazy: a project with `effects:` and
        # no annotation pays it and stops. It is also **skipped entirely** when there is no loader — a
        # project that writes no RBS at all still gets the configured envelopes judged, which is the whole
        # point of the convention surface (design note § 6.2, "value on day one").
        def declaration_diagnostics
          scan = scan_declarations
          return NO_DIAGNOSTICS if scan.nil? && config_envelopes.empty?

          unknown_label_diagnostics(scan) + exceeded_diagnostics(scan)
        end

        def scan_declarations
          return nil if @rbs_loader.nil?

          scan = RbsExtended::EnvelopeScanner.scan(sources: signature_sources, registry: registry)
          scan.empty? ? nil : scan
        end

        # The envelope contract itself. Needs the propagated graph and the discovery tables the `def`
        # positions come from, so it is skipped when collection produced nothing — an unrecognised
        # label is still reported in that case, because it is a fact about the declaration alone.
        def exceeded_diagnostics(scan)
          return NO_DIAGNOSTICS if @effect_table.empty?

          judge(scan).map { |finding| build_diagnostic(finding) }
        end

        def unknown_label_diagnostics(scan)
          return NO_DIAGNOSTICS if scan.nil?

          findings = Effects::UnknownLabelCheck.for_envelopes(
            method_envelopes: scan.method_envelopes, class_envelopes: scan.class_envelopes,
            registry: registry
          )
          build_unknown_label_diagnostics(findings)
        end

        # The `.rigor.yml` label lists. Their SHAPE is already a tier-2 load error; this is the other
        # half, a member the registry does not know after plugin load, which would otherwise fail
        # silently — a `tolerated:` entry that discharges nothing, an envelope that reads ⊤, an
        # attribution nothing can interpret.
        def config_label_diagnostics
          findings = config_label_findings("effects.tolerated", @configuration.effects_tolerated,
                                           TOLERATED_CONSEQUENCE) +
                     config_label_findings("effects.labels", @configuration.effects_labels,
                                           LABELS_CONSEQUENCE) +
                     attribution_findings
          build_unknown_label_diagnostics(findings)
        end

        def config_label_findings(key_path, labels, consequence)
          return [] if labels.empty?

          Effects::UnknownLabelCheck.for_config(
            labels: labels, key_path: key_path, consequence: consequence, registry: registry
          )
        end

        def attribution_findings
          @configuration.effects_attribution.flat_map do |key, labels|
            config_label_findings("effects.attribution.#{key}", labels, ATTRIBUTION_CONSEQUENCE)
          end
        end

        # `envelopes[].effect` — reported per entry, so the message names the stanza a reader has to edit
        # rather than the label list it happens to share with another entry.
        def config_envelope_diagnostics
          findings = config_envelopes_entries.flat_map do |entry|
            next [] if entry.unknown_labels.empty?

            config_label_findings("effects.envelopes[#{entry.index}].effect", entry.labels,
                                  ENVELOPE_CONSEQUENCE)
          end
          build_unknown_label_diagnostics(findings)
        end

        def build_unknown_label_diagnostics(findings)
          findings.map { |finding| build_unknown_label_diagnostic(finding) }
                  .sort_by { |diagnostic| [diagnostic.path, diagnostic.line, diagnostic.message] }
        end

        def build_unknown_label_diagnostic(finding)
          path, line = position_of(finding)
          Diagnostic.new(
            path: path, line: line, column: 1, message: finding.message,
            severity: :info, rule: UNKNOWN_LABEL_RULE, source_family: :builtin
          )
        end

        # The declaration, not the method: this is a fact about what the author wrote, and the fix is
        # on that line. A `.rbs` position is the right answer here even though its sibling deliberately
        # avoids one (the `rbs_extended.unsatisfied-conformance` precedent) — there is no Ruby `def`
        # that could carry the typo.
        def position_of(finding)
          location = finding.location
          return [CONFIG_PATH, 1] if location.nil?

          path, _, raw_line = location.rpartition(":")
          return [CONFIG_PATH, 1] if path.empty?

          line = raw_line.to_i
          line = 1 unless line.positive?
          path.end_with?(RUBY_EXTENSION) ? [path, inline_line(path, finding.spelling) || line] : [path, line]
        end

        # rbs-inline's writer re-emits the author's own comment block ABOVE the annotation it
        # generates, so a line number read out of the synthesized buffer drifts from the `.rb` line the
        # author actually wrote — by the length of every method body above it. The annotation's own
        # text is unique enough to find again, so the Ruby file is what answers. One read, and only
        # when a finding already exists.
        def inline_line(path, spelling)
          return nil if spelling.nil?

          source = @sources[path] || File.read(path)
          source.each_line.with_index(1) { |line, number| return number if line.include?(spelling) }
          nil
        rescue StandardError
          nil
        end

        # The vocabulary an unknown label is judged against: the shipped registry plus whatever
        # `effects.labels:` opened. A project may open any root — the listing IS the vouching act — so
        # nothing here can raise on ownership; plugin-registered roots join in #387, and this stays the
        # one place that changes.
        def registry
          @registry ||= Effects::Registry.for_configuration(@configuration)
        end

        # `effects.envelopes:`, resolved against the vocabulary once per run.
        def config_envelopes_entries
          @config_envelopes_entries ||= Effects::ConfigEnvelopes.build(
            entries: @configuration.effects_envelopes, registry: registry
          )
        end

        # The classes those entries select, as class-keyed envelopes. Keyed off the effect table's own
        # class names, so an entry naming a namespace or a path with no analysed unit behind it simply
        # selects nothing.
        def config_envelopes
          @config_envelopes ||= Effects::ConfigEnvelopes.for_classes(
            entries: config_envelopes_entries, class_names: table_class_names, sources: @unit_sources
          )
        end

        def table_class_names
          @effect_table.keys.filter_map { |key| Effects::MethodKey.owner(key) }.uniq
        end

        def judge(scan)
          def_sources, singleton_def_sources, class_sources = @discovery.call
          Effects::EnvelopeCheck.run(
            table: @effect_table,
            method_envelopes: scan&.method_envelopes || {}, class_envelopes: scan&.class_envelopes || {},
            config_envelopes: config_envelopes,
            positions: Effects::EnvelopeCheck::Positions.build(
              def_sources: def_sources, singleton_def_sources: singleton_def_sources,
              class_sources: class_sources
            ),
            apply_tolerated: @apply_tolerated
          )
        end

        # Everything an envelope may be written in — {Effects::SignatureSources} owns the stratum rule.
        def signature_sources
          Effects::SignatureSources.collect(
            signature_paths: @configuration.signature_paths, virtual_rbs: @rbs_loader.virtual_rbs
          )
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

        # A distributed annotation names the class it came from; a configured envelope does not, because
        # its `location` already names the stanza (`.rigor.yml effects.envelopes[2]`) and the method key
        # at the head of the message already names the class.
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

        # Only a Ruby file has Ruby comments. An `effect.unknown-label` positioned in `.rbs` or at
        # `.rigor.yml` is suppressible by the `disable:` list and by the baseline, never by an in-file
        # comment — parsing YAML or RBS as Ruby to look for one would be a lie dressed as a feature.
        def comments_for(path)
          return [].freeze unless path.end_with?(RUBY_EXTENSION)

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
