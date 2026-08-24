# frozen_string_literal: true

require_relative "envelope"
require_relative "envelope_check"
require_relative "method_key"
require_relative "path_finder"

module Rigor
  module Effects
    # Judges an override against the envelope it inherits (ADR-103 WD1 / WD14; #386). The one place
    # `effect.liskov-widened` is decided.
    #
    # An envelope is a contract about a method, and Ruby's `class PgRepo < Repo` says a `PgRepo` is
    # usable wherever a `Repo` is. So a bound written on `Repo#find` binds `PgRepo#find` too:
    # **implementations may be purer than the bound they inherit, never less pure.** That is Liskov
    # inclusion applied to the second dimension, and it is what makes the declared lane's nominal carrier
    # (#386, {EnvelopeIndex}) honest — a caller that imports `≤ io.db` from a `Repo`-typed receiver is
    # entitled to that bound whichever subclass actually arrives.
    #
    # Two comparisons, and an override is subject to exactly one of them:
    #
    # - **Proven against the inherited bound** — the override declares nothing of its own, so what it
    #   *does* is what the ancestor's bound has to admit. It reads the same lane
    #   {EnvelopeCheck} reads, for the same reasons: the proven closure, undischarged per policy,
    #   `mutate.local` tolerated, taint ignored.
    # - **Declared against the inherited bound** — the override declares its own envelope, and a bound
    #   wider than the one it inherits is a Liskov violation in the *declaration*, before any body is
    #   consulted. Two authored bounds compared by subsumption; nothing proven enters it.
    #
    # The split is exclusive on purpose. An override that declares its own envelope is already held to
    # that envelope by `effect.envelope-exceeded`, so running the proven comparison too would put two
    # diagnostics on one line for one label. What the author asserted is the thing Liskov has to judge;
    # whether the body honours the assertion is the other rule's question.
    #
    # Both-sides-authored, in the [ADR-35](../../../docs/adr/35-override-signature-compatibility.md)
    # sense: nothing fires unless an author wrote an envelope on the ancestor. That is the accepted
    # construction the false-positive budget is spent under — a firing is never unsolicited.
    #
    # **Nominal subclassing only.** An included module's method is not an override in this slice: Ruby's
    # ancestry puts an includer's own `def` *ahead* of the module's rather than under it, and the
    # substitutability argument that licenses the check is the subclass one. The `superclasses` table is
    # the collector's own, as-written and resolved here exactly as {Propagator} resolves it, so the
    # relation the check reads and the closed world the proven lane travels can never disagree.
    module LiskovCheck
      # One (override, exceeding label) pair.
      #
      # `own_envelope` is the override's own bound when there is one, which is also what selects the
      # message variant: present means the declaration-level comparison produced this finding, nil means
      # the proven one. `chain` / `origin` explain the proven variant and are nil for the other, which
      # has no path to walk — a declaration is not proved by anything.
      Finding = Data.define(:key, :label, :ancestor_key, :ancestor_envelope, :own_envelope, :path, :line,
                            :chain, :origin)

      NO_FINDINGS = [].freeze
      private_constant :NO_FINDINGS

      module_function

      # @param table [EffectTable] the run's propagated graph.
      # @param superclasses [Hash{String => Array<String>}] the collector's as-written superclass
      #   candidate lists (`FileCollection#superclasses`).
      # @param method_envelopes [Hash{String => Envelope}] per-method envelopes, as written.
      # @param class_envelopes [Hash{String => Envelope}] class- / module-level envelopes, to distribute.
      # @param config_envelopes [Hash{String => Envelope}] `effects.envelopes:` entries already resolved
      #   to the classes they select.
      # @param positions [EnvelopeCheck::Positions] where the override's `def` is.
      # @param apply_tolerated [Boolean] false judges against `proven` — `--no-tolerated-effects`.
      # @return [Array<Finding>] sorted by position then key then label.
      def run(table:, superclasses:, method_envelopes:, class_envelopes:, config_envelopes: {},
              positions: EnvelopeCheck::Positions.empty, apply_tolerated: true)
        # The distributed strata, over a base of the raw per-method annotations: a base class whose method
        # exists only in `.rbs` — an abstract `def find: (Integer) -> User` with no Ruby body — has no
        # key in the table and so no distributed entry, and its bound is exactly the one an override
        # inherits. Distribution wins on collision, which is the same value for a key that has both.
        envelopes = method_envelopes.merge(
          EnvelopeCheck.distribute(table, method_envelopes, class_envelopes, config_envelopes)
        )
        return NO_FINDINGS if envelopes.empty?

        parents = parent_map(table, superclasses)
        return NO_FINDINGS if parents.empty?

        findings = []
        keys = table.keys
        keys.each { |key| collect(findings, table, key, envelopes, parents, positions, apply_tolerated) }
        findings.sort_by { |f| [f.path.to_s, f.line, f.key, f.label] }.freeze
      end

      # `{child class => parent class}`, one parent per child.
      #
      # An ancestry name is recorded as written, so `class Loud < Base` inside `module Tracer` arrives as
      # the candidate list Ruby's own lexical lookup would try, most-qualified first. The most-qualified
      # candidate the project actually defines wins — the same rule {Propagator::Index#build_descendants}
      # applies, and for the same reason: without it `A::Base` and `B::Base` would share the bare spelling
      # `Base` and an unrelated class's envelope would bind an override that never inherited it.
      def parent_map(table, superclasses)
        return {} if superclasses.nil? || superclasses.empty?

        known = table.keys.filter_map { |key| MethodKey.owner(key) }.to_set
        superclasses.each_with_object({}) do |(child, candidates), out|
          parent = Array(candidates).find { |candidate| known.include?(candidate) }
          out[child] = parent if parent && parent != child
        end
      end

      def collect(findings, table, key, envelopes, parents, positions, apply_tolerated)
        class_name, separator, selector = MethodKey.split(key)
        return if class_name.nil?

        ancestor_key = inherited_key(class_name, separator, selector, envelopes, parents)
        return if ancestor_key.nil?

        inherited = envelopes.fetch(ancestor_key)
        own = envelopes[key]
        # The position is read inside the two collectors, after they know a finding exists: `.for` is
        # what forces a deferred position table, and an inherited envelope nothing widens must not
        # cost a whole-project discovery parse.
        if own && !own.top?
          collect_declared(findings, key, ancestor_key, inherited, own, positions)
        else
          collect_proven(findings, table, key, ancestor_key, inherited, positions, apply_tolerated)
        end
      end

      # The nearest ancestor whose own method key carries an envelope. Nearest wins for the same reason
      # it does among strata: a bound written closer to the override is the more specific statement about
      # it, and a grandparent's bound is already binding on the parent that sits between them.
      def inherited_key(class_name, separator, selector, envelopes, parents)
        seen = Set.new([class_name])
        current = parents[class_name]
        while current && seen.add?(current)
          candidate = "#{current}#{separator}#{selector}"
          return candidate if envelopes.key?(candidate) && !envelopes.fetch(candidate).top?

          current = parents[current]
        end
        nil
      end

      def collect_proven(findings, table, key, ancestor_key, inherited, positions, apply_tolerated)
        entry = table[key]
        return if entry.nil?

        exceeding = inherited.exceeded_by(apply_tolerated ? entry.undischarged : entry.proven)
        return if exceeding.empty?

        path, line = positions.for(key)
        exceeding.each do |label|
          trail = PathFinder.shortest(table, symbol: key, label: label)
          findings << Finding.new(
            key: key, label: label, ancestor_key: ancestor_key, ancestor_envelope: inherited,
            own_envelope: nil, path: path, line: line,
            chain: trail&.chain || [key].freeze, origin: trail&.origin
          )
        end
      end

      # Two authored bounds, compared by subsumption alone. `mutate.local` is tolerated here as it is
      # everywhere, so declaring it under an inherited `%a{pure}` is not a widening.
      def collect_declared(findings, key, ancestor_key, inherited, own, positions)
        widened = own.bound.to_a.reject { |label| inherited.tolerates?(label) }
        return if widened.empty?

        path, line = positions.for(key)
        widened.each do |label|
          findings << Finding.new(
            key: key, label: label, ancestor_key: ancestor_key, ancestor_envelope: inherited,
            own_envelope: own, path: path, line: line, chain: nil, origin: nil
          )
        end
      end

      private_class_method :parent_map, :collect, :inherited_key, :collect_proven, :collect_declared
    end
  end
end
