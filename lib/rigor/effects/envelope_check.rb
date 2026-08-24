# frozen_string_literal: true

require_relative "envelope"
require_relative "effect_table"
require_relative "method_key"
require_relative "path_finder"

module Rigor
  module Effects
    # Judges each method's declared envelope against what the run actually proved (ADR-103 WD1 / WD8;
    # #383). The one place `effect.envelope-exceeded` is decided.
    #
    # Three rules make this FP-safe, and each is load-bearing:
    #
    # - **It reads the PROVEN lane only**, never the declared one and never taint. A non-exhaustive
    #   summary reads "these effects, and possibly more" and contributes no finding of its own; what
    #   it *did* prove is still proven, so a proven label outside the bound still fires. That is "as
    #   strict as proven" ([robustness-principle.md](../../../docs/type-specification/robustness-principle.md)),
    #   and it is why an unresolved call can never manufacture one.
    # - **The bound binds the method's CODE, transitively.** The envelope is a contract about what the
    #   method does, and a repository that calls a helper that calls `Net::HTTP` does perform HTTP. So
    #   the comparison is against {EffectTable::Entry#proven} — the fixpoint's closure over project
    #   callees — not against the unit's own direct summary.
    # - **`mutate.local` is tolerated by every envelope**, `%a{pure}` included ({Envelope#tolerates?}).
    #
    # **`effects.tolerated:` discharges, per origin** (#385). The comparison reads
    # {EffectTable::Entry#undischarged} rather than `proven`: the propagator has already dropped every
    # origin bundle the policy discharges and closed the rest over the graph, so a `pure`-declared method
    # that logs is silent under `tolerated: [telemetry]` while the `File.read` two lines down still fires.
    # `apply_tolerated: false` — `--no-tolerated-effects` — judges against `proven` instead, which is the
    # audit switch that makes the policy inspectable rather than invisible.
    module EnvelopeCheck
      # One (method, exceeding label) pair. `chain` is the shortest project-method path from the
      # method to whatever proves the label and `origin` is the callee key or construct at its end —
      # the same explanation `rigor effects explain` prints, so the diagnostic tells a reader where to
      # look rather than only that something is wrong.
      Finding = Data.define(:key, :label, :envelope, :path, :line, :chain, :origin)

      # The discovery tables a finding's POSITION is read from, as one value — `discovered_def_sources`
      # (`{class => {method_sym => "path:line"}}`), its `def self.x` mirror, and `discovered_class_sources`
      # (`{class => Set[path]}`), the fallback for a method with no Ruby `def` at all. Kept together so the
      # check's own signature stays about the judgment rather than about where a `def` lives.
      class Positions < Data.define(:def_sources, :singleton_def_sources, :class_sources)
        NONE = {}.freeze
        private_constant :NONE

        def self.empty
          @empty ||= build
        end

        def self.build(def_sources: nil, singleton_def_sources: nil, class_sources: nil)
          new(def_sources: def_sources || NONE, singleton_def_sources: singleton_def_sources || NONE,
              class_sources: class_sources || NONE)
        end

        # Where a finding about `key` goes: the Ruby `def`, from the discovery tables (ADR-103 WD14 chose
        # the `def` over the `.rbs` line deliberately — `# rigor:disable` reads only Ruby comments). A
        # method with no `def` at all is a synthesized accessor, and the class's own source is the closest
        # thing to a position it has.
        #
        # It lives on the value rather than in {EnvelopeCheck} because {LiskovCheck} positions its
        # findings identically, and two spellings of "where the fix goes" would eventually disagree.
        #
        # @return [Array(String, Integer)] `[path, line]`; `[nil, 1]` for a key with no owner.
        def for(key)
          class_name, separator, selector = MethodKey.split(key)
          return [nil, 1] if class_name.nil?

          table = separator == "." ? singleton_def_sources : def_sources
          site = table.dig(class_name, selector.to_sym)
          return split_site(site) if site

          [Array(class_sources[class_name]).first, 1]
        end

        private

        def split_site(site)
          path, _, line = site.to_s.rpartition(":")
          return [site.to_s, 1] if path.empty?

          [path, line.to_i.positive? ? line.to_i : 1]
        end
      end

      # {Positions} behind a thunk: the discovery tables — one Prism parse of every project file —
      # are built on the first `.for`, which both judgments reach only once a finding is being
      # constructed. A clean judgment, the common CI case, therefore forces no discovery and parses
      # nothing; that is the whole point of this class existing rather than the pass forcing the
      # tables up front.
      class DeferredPositions
        def initialize(&build)
          @build = build
        end

        def for(key)
          (@positions ||= @build.call).for(key)
        end
      end

      NO_FINDINGS = [].freeze
      private_constant :NO_FINDINGS

      module_function

      # @param table [EffectTable] the run's propagated graph.
      # @param method_envelopes [Hash{String => Envelope}] per-method envelopes, as written.
      # @param class_envelopes [Hash{String => Envelope}] class- / module-level envelopes, to distribute.
      # @param config_envelopes [Hash{String => Envelope}] `effects.envelopes:` entries already resolved
      #   to the classes they select ({ConfigEnvelopes.for_classes}), to distribute at the lowest precedence.
      # @param positions [Positions, DeferredPositions] the discovery tables a finding's `def`
      #   position is read from — consulted only when a finding is built, so a deferred value's
      #   discovery force is reached exactly as often as a finding exists.
      # @param apply_tolerated [Boolean] false judges against the undischarged-by-policy `proven` lane —
      #   the `--no-tolerated-effects` audit switch.
      # @return [Array<Finding>] sorted by position then key then label, so a run explains identically twice.
      def run(table:, method_envelopes:, class_envelopes:, config_envelopes: {},
              positions: Positions.empty, apply_tolerated: true)
        envelopes = distribute(table, method_envelopes, class_envelopes, config_envelopes)
        return NO_FINDINGS if envelopes.empty?

        findings = []
        envelopes.each do |key, envelope|
          collect(findings, table, key, envelope, positions, apply_tolerated)
        end
        findings.sort_by { |f| [f.path.to_s, f.line, f.key, f.label] }.freeze
      end

      # Resolves the per-method envelope for every unit the table knows, **nearest wins**:
      #
      #     per-method annotation  >  class-level annotation  >  `effects.envelopes:` entry
      #
      # The two class-shaped strata distribute identically — an envelope keyed by a class name reaches
      # every method key of THAT Ruby class, so a subclass's keys never match and a module distributes to
      # its own methods only — and are applied in that order, so a written annotation always wins over a
      # convention. Which config entry a class matched was already decided by {ConfigEnvelopes.for_classes}.
      #
      # Public because {LiskovCheck} resolves the *ancestor's* envelope by exactly these rules: an
      # inherited bound has to be the same bound the ancestor is itself held to, or the two checks would
      # disagree about what the author wrote.
      def distribute(table, method_envelopes, class_envelopes, config_envelopes)
        resolved = {}
        unless class_envelopes.empty? && config_envelopes.empty?
          keys_by_class(table).each do |class_name, keys|
            envelope = class_envelopes[class_name] || config_envelopes[class_name]
            next if envelope.nil?

            keys.each { |key| resolved[key] = envelope.rebind(key) }
          end
        end
        method_envelopes.each { |key, envelope| resolved[key] = envelope if table[key] }
        resolved
      end

      # `{class name => [method key]}` over the units the run collected — the "every method discovery
      # knows" of the class-level distribution rule, including reopenings in other files and the
      # synthesized `attr_*` / `define_method` members the effects scanner adds.
      def keys_by_class(table)
        table.keys.each_with_object({}) do |key, out|
          owner = MethodKey.owner(key)
          next if owner.nil?

          (out[owner] ||= []) << key
        end
      end

      def collect(findings, table, key, envelope, positions, apply_tolerated)
        return if envelope.top?

        entry = table[key]
        return if entry.nil?

        exceeding = envelope.exceeded_by(apply_tolerated ? entry.undischarged : entry.proven)
        return if exceeding.empty?

        path, line = positions.for(key)
        exceeding.each do |label|
          trail = PathFinder.shortest(table, symbol: key, label: label)
          findings << Finding.new(
            key: key, label: label, envelope: envelope, path: path, line: line,
            chain: trail&.chain || [key].freeze, origin: trail&.origin
          )
        end
      end

      private_class_method :keys_by_class, :collect
    end
  end
end
