# frozen_string_literal: true

module Rigor
  # ADR-50 § WD2 — the bleeding-edge overlay.
  #
  # A Rigor-maintained set of the *next major's* queued changes — severity-map promotions and
  # new-discipline rule enablements — that a user can adopt early, before they become
  # default-on at a major (ADR-50 § WD7). It is orthogonal to `severity_profile:` (how loud
  # *today's* rules are) and is versioned with the gem, NOT a user-supplied file: the
  # inspectable counterpart to PHPStan's `bleedingEdge` include.
  #
  # The WD2 foundation slice wired the surface end-to-end (`bleeding_edge:` config, the
  # `rigor show-bleedingedge` command, the severity-composition hook in
  # {Configuration::SeverityProfile.resolve}), so a *severity* discipline lands as a single
  # {FEATURES} entry with no engine plumbing — as the first one,
  # `reject-unparseable-signatures`, does.
  #
  # A queued change whose effect is not a severity move — a measurement, an algorithm, or a
  # default that changes while every rule keeps its severity — is a `:behaviour` feature
  # instead. It carries no severity map; its call sites ask
  # {Configuration#bleeding_edge_active?} whether the id is adopted for the run.
  #
  # A `:behaviour` feature MUST NOT change the output of `rigor check` analysis unless its
  # feature id is folded into the analysis-cache identity. Rationale, verified 2026-08-01:
  # severity features are safe because severity is stamped POST-cache — {Analysis::SeverityStamp}
  # (ADR-87 WD4) stores the authored severity and applies the profile + bleeding-edge overrides
  # identically on the miss path and the warm-hit path, so a warm HIT re-resolves under the
  # current selector. A behaviour feature that altered analysis results themselves would poison
  # warm caches across selector changes, because the selector is not part of the cache key. The
  # two queued consumers (#253, #254) change what a separate command measures, not what `check`
  # analyses, so neither is affected.
  #
  # Each feature carries a **stable feature id** — part of the ADR-50 WD1 contract
  # vocabulary: the config, the `show` command, and the eventual CHANGELOG migration note all
  # name the same id, and a feature graduates to default-on at a major (ADR-50 § WD7) by
  # moving from {FEATURES} to {GRADUATED}.
  module BleedingEdge
    # The two kinds a queued change can take. `:severity` composes through
    # {Configuration::SeverityProfile.resolve}; `:behaviour` is read at a call site through
    # {Configuration#bleeding_edge_active?}.
    KINDS = %i[severity behaviour].freeze

    # The severity map a `:behaviour` feature carries: none.
    NO_SEVERITY_OVERRIDES = {}.freeze

    # One queued change.
    #
    # The two kinds are exclusive by construction: a `:severity` feature MUST name at least
    # one rule, and a `:behaviour` feature MUST name none — a behaviour switch that also
    # moved a severity would be two changes wearing one id, and the id is what a CHANGELOG
    # migration note and a user's `bleeding_edge:` list both key on.
    #
    # @!attribute id
    #   @return [String] the stable feature id (contract vocabulary).
    # @!attribute summary
    #   @return [String] a one-line description of what it changes. For a `:behaviour`
    #     feature this is the *whole* explanation — there is no severity diff to read.
    # @!attribute kind
    #   @return [Symbol] one of {KINDS}.
    # @!attribute severity_overrides
    #   @return [Hash{String => Symbol}] canonical rule id → the severity this feature
    #     imposes. Composed *below* the user's own `severity_overrides:` and *above* the
    #     active `severity_profile` (see {Configuration::SeverityProfile.resolve}). Empty for
    #     a `:behaviour` feature.
    Feature = Data.define(:id, :summary, :kind, :severity_overrides) do
      def initialize(id:, summary:, kind:, severity_overrides: NO_SEVERITY_OVERRIDES)
        raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}" unless KINDS.include?(kind)

        if kind == :severity && severity_overrides.empty?
          raise ArgumentError, "bleeding-edge feature #{id.inspect} is :severity but overrides no rule"
        end
        if kind == :behaviour && !severity_overrides.empty?
          raise ArgumentError, "bleeding-edge feature #{id.inspect} is :behaviour but carries severity_overrides"
        end

        super
      end

      # @return [Boolean]
      def severity?
        kind == :severity
      end

      # @return [Boolean]
      def behaviour?
        kind == :behaviour
      end

      def to_h
        {
          "id" => id,
          "summary" => summary,
          "kind" => kind.to_s,
          "severity_overrides" => severity_overrides.transform_values(&:to_s)
        }
      end
    end

    # The overlay.
    #
    # Feature ids are **kebab-case, and name the discipline rather than the rule** it happens to
    # promote (`reject-unparseable-signatures`, not `rbs-quarantine-error`): a discipline may grow
    # to cover more rules without its id going stale, and the id is contract vocabulary that
    # outlives the rule set it started with.
    FEATURES = [
      Feature.new(
        id: "reject-unparseable-signatures",
        kind: :severity,
        summary: "A broken `signature_paths:` RBS set fails the run instead of degrading it silently. An " \
                 "unparseable `.rbs` is otherwise skipped with a warning, and a duplicate-declaration " \
                 "conflict (a file that parses fine but collides on resolve — typically against Rigor's " \
                 "own bundled RBS) collapses the whole env with a warning; either way the run gets quieter " \
                 "rather than cleaner. This treats both as a build error, the way a broken source file " \
                 "already is.",
        severity_overrides: {
          "rbs.coverage.quarantined-signature" => :error,
          "rbs.coverage.environment-build-failed" => :error
        }.freeze
      ),
      Feature.new(
        id: "use-of-void-value",
        kind: :severity,
        summary: "Using a value recovered from an author-declared `-> void` return in value context (an " \
                 "assignment right-hand side, a call receiver, or an argument) becomes a `:warning`. An " \
                 "explicit `-> void` is the strongest possible \"do not rely on this return\" signal, so " \
                 "the direct-dispatch case is FP-narrow; a bare-statement `void` result and a legitimate " \
                 "`top` value both stay silent. Off by default because a new required diagnostic is an " \
                 "ADR-50 WD1 compatibility change (ADR-100 WD2).",
        severity_overrides: {
          "static.value-use.void" => :warning
        }.freeze
      ),
      Feature.new(
        id: "discovery-seeded-mutation-sites",
        kind: :behaviour,
        summary: "`rigor coverage --protection --mutation` (Tier 2) measures against the same cross-file " \
                 "project discovery Tier 1 already seeds, instead of an empty scope — both when picking the " \
                 "sites and when re-analysing each breakage to decide whether it was caught. A call whose " \
                 "receiver is a project class declared in a *sibling* file (`Post.where`, " \
                 "`Rigor::Protection::Mutator.new`) then resolves to the type it really has rather than " \
                 "`Dynamic`, so the site is measured instead of dropped — and a breakage there can actually " \
                 "be caught. This makes the two tiers judge a site " \
                 "by one standard, but it ADDS sites to the denominator, so the reported effectiveness ratio " \
                 "goes DOWN on the same code — and `--threshold=RATIO` exits 1 when that ratio falls below a " \
                 "number pinned in CI. Off by default for that reason: it is a queued change for the next " \
                 "major, not a fix you should be opted into mid-release."
      ),
      Feature.new(
        id: "dependent-closure-kill-oracle",
        kind: :behaviour,
        summary: "`rigor coverage --protection --mutation` (Tier 2) decides a breakage was caught when the " \
                 "diagnostic appears anywhere in the mutated file OR the files that depend on it, instead of " \
                 "in the mutated file alone. Changing what a method returns is caught in its *callers* — the " \
                 "cross-file reach the analyzer exists for — and that catch is scored as a miss today. The " \
                 "measurement re-analyses the dependent closure (ADR-46's dependency graph) against the " \
                 "mutated bytes, so those catches count. It can only ADD kills, never remove one, so the " \
                 "reported ratio moves up or not at all; a recorded ratio nonetheless stops being comparable " \
                 "with one measured without it. It costs roughly a third more wall time per mutant, and on " \
                 "the two corpora measured so far (Rigor's own `lib`, redmine `app/models`) it added no " \
                 "kills — every surviving breakage there is one the analyzer reports nowhere at all, not one " \
                 "it reports in a caller."
      )
    ].freeze

    # ADR-50 § WD7 — the ids that have already graduated to default-on.
    #
    # A feature graduates at a major by moving *here* from {FEATURES} rather than by simply
    # disappearing: {Configuration#bleeding_edge_active?} then answers an unconditional `true`
    # for the id, so a call site still asking about it keeps the graduated behaviour and gate
    # cleanup can lag graduation by as many releases as it takes. The id also stays in the
    # contract vocabulary the CHANGELOG migration note keys on. Entries are removed only once
    # no call site names them.
    #
    # @return [Array<String>]
    GRADUATED = [].freeze

    module_function

    # @return [Array<Feature>] the whole overlay.
    def features
      FEATURES
    end

    # @return [Array<String>] every feature id in the overlay.
    def feature_ids
      FEATURES.map(&:id)
    end

    # @param id [String]
    # @return [Feature, nil]
    def feature(id)
      FEATURES.find { |f| f.id == id }
    end

    # @param id [String]
    # @return [Boolean] whether the id has graduated to default-on ({GRADUATED}).
    def graduated?(id)
      GRADUATED.include?(id)
    end

    # @param id [String]
    # @return [Boolean] whether the id names a feature this gem knows at all — queued or
    #   graduated. Distinct from "adopted"; see {Configuration#bleeding_edge_active?}.
    def known_id?(id)
      graduated?(id) || FEATURES.any? { |f| f.id == id }
    end

    # Resolves a normalized `bleeding_edge:` selector (see {Configuration#bleeding_edge}) to
    # the active {Feature} list. Unknown ids in a `list` / `except` selector are simply
    # absent from the overlay and contribute nothing — symmetric with how
    # `severity_overrides:` keeps an unknown rule id inert until it lands (robust across gem
    # versions).
    #
    # @param selector [Hash] `{ "mode" => "none" }`,
    #   `{ "mode" => "all" }`, `{ "mode" => "all", "except" => [ids] }`,
    #   or `{ "mode" => "list", "ids" => [ids] }`.
    # @return [Array<Feature>]
    def active_features(selector)
      case selector["mode"]
      when "all"
        except = selector["except"] || []
        FEATURES.reject { |f| except.include?(f.id) }
      when "list"
        ids = selector["ids"] || []
        FEATURES.select { |f| ids.include?(f.id) }
      else
        []
      end
    end

    # The merged severity-override map the active features impose for a selector. Frozen so
    # the result is `Ractor.shareable?`.
    #
    # @param selector [Hash] see {#active_features}.
    # @return [Hash{String => Symbol}]
    def severity_overrides_for(selector)
      active_features(selector).each_with_object({}) do |feature, acc|
        acc.merge!(feature.severity_overrides)
      end.freeze
    end

    # The ids the active features expose to {Configuration#bleeding_edge_active?}, as a frozen
    # `Set` so a call site on the hot path pays a hash lookup rather than an Array scan.
    # Precomputed once per Configuration; frozen (with frozen members) so the carrier stays
    # `Ractor.shareable?` across the worker boundary.
    #
    # @param selector [Hash] see {#active_features}.
    # @return [Set<String>]
    def active_ids_for(selector)
      Set.new(active_features(selector).map(&:id)).freeze
    end

    # Feature ids named by a selector that are NOT in the overlay (typo / graduated / from a
    # newer gem). Surfaced by `rigor show-bleedingedge` as a hint; never an error.
    #
    # @param selector [Hash] see {#active_features}.
    # @return [Array<String>]
    def unknown_selected_ids(selector)
      named =
        case selector["mode"]
        when "list" then selector["ids"] || []
        when "all"  then selector["except"] || []
        else []
        end
      known = feature_ids
      named.reject { |id| known.include?(id) }
    end
  end
end
