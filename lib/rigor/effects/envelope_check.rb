# frozen_string_literal: true

require_relative "envelope"
require_relative "effect_table"
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
    # `effects.tolerated:` is deliberately NOT consulted here. That list is a *judgment*-time policy
    # for the snapshot's diff (ADR-103 WD7: the record is undischarged), and wiring it into the
    # envelope check is #385's business, not this slice's.
    module EnvelopeCheck
      # One (method, exceeding label) pair. `chain` is the shortest project-method path from the
      # method to whatever proves the label and `origin` is the callee key or construct at its end —
      # the same explanation `rigor effects explain` prints, so the diagnostic tells a reader where to
      # look rather than only that something is wrong.
      Finding = Data.define(:key, :label, :envelope, :path, :line, :chain, :origin)

      NO_FINDINGS = [].freeze
      private_constant :NO_FINDINGS

      module_function

      # @param table [EffectTable] the run's propagated graph.
      # @param method_envelopes [Hash{String => Envelope}] per-method envelopes, as written.
      # @param class_envelopes [Hash{String => Envelope}] class- / module-level envelopes, to distribute.
      # @param def_sources [Hash] `discovered_def_sources` — `{class => {method_sym => "path:line"}}`.
      # @param singleton_def_sources [Hash] its `def self.x` mirror.
      # @param class_sources [Hash] `discovered_class_sources` — `{class => Set[path]}`, the fallback
      #   position for a method with no Ruby `def` (a synthesized `attr_*` accessor).
      # @return [Array<Finding>] sorted by position then key then label, so a run explains identically twice.
      def run(table:, method_envelopes:, class_envelopes:,
              def_sources: {}, singleton_def_sources: {}, class_sources: {})
        envelopes = distribute(table, method_envelopes, class_envelopes)
        return NO_FINDINGS if envelopes.empty?

        findings = []
        envelopes.each do |key, envelope|
          collect(findings, table, key, envelope, def_sources, singleton_def_sources, class_sources)
        end
        findings.sort_by { |f| [f.path.to_s, f.line, f.key, f.label] }.freeze
      end

      # Resolves the per-method envelope for every unit the table knows. A class-level envelope reaches
      # every method of THAT Ruby class — its key is the class name, so a subclass's keys never match
      # and a module distributes to its own methods only — and a per-method envelope wins over it.
      def distribute(table, method_envelopes, class_envelopes)
        resolved = {}
        unless class_envelopes.empty?
          keys_by_class(table).each do |class_name, keys|
            envelope = class_envelopes[class_name]
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
          index = key.index("#") || key.index(".")
          next if index.nil?

          (out[key[0, index]] ||= []) << key
        end
      end

      def collect(findings, table, key, envelope, def_sources, singleton_def_sources, class_sources)
        return if envelope.top?

        entry = table[key]
        return if entry.nil?

        exceeding = envelope.exceeded_by(entry.proven)
        return if exceeding.empty?

        path, line = position(key, def_sources, singleton_def_sources, class_sources)
        exceeding.each do |label|
          trail = PathFinder.shortest(table, symbol: key, label: label)
          findings << Finding.new(
            key: key, label: label, envelope: envelope, path: path, line: line,
            chain: trail&.chain || [key].freeze, origin: trail&.origin
          )
        end
      end

      # Where the fix goes: the Ruby `def`, from the discovery tables (ADR-103 WD14 chose the `def`
      # over the `.rbs` line deliberately — `# rigor:disable` reads only Ruby comments). A method with
      # no `def` is a synthesized accessor, and the class's own source is the closest thing to a
      # position it has.
      def position(key, def_sources, singleton_def_sources, class_sources)
        index = key.index("#") || key.index(".")
        return [nil, 1] if index.nil?

        class_name = key[0, index]
        method_name = key[(index + 1)..].to_s.to_sym
        table = key[index] == "." ? singleton_def_sources : def_sources
        site = table.dig(class_name, method_name)
        return split_site(site) if site

        [Array(class_sources[class_name]).first, 1]
      end

      def split_site(site)
        path, _, line = site.to_s.rpartition(":")
        return [site.to_s, 1] if path.empty?

        [path, line.to_i.positive? ? line.to_i : 1]
      end

      private_class_method :distribute, :keys_by_class, :collect, :position, :split_site
    end
  end
end
