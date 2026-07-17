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
  # {Configuration::SeverityProfile.resolve}), so a discipline lands as a single {FEATURES}
  # entry with no engine plumbing — as the first one, `reject-unparseable-signatures`, does.
  #
  # Each feature carries a **stable feature id** — part of the ADR-50 WD1 contract
  # vocabulary: the config, the `show` command, and the eventual CHANGELOG migration note all
  # name the same id, and a feature graduates to default-on at a major by being removed from
  # {FEATURES}.
  module BleedingEdge
    # One queued change.
    #
    # @!attribute id
    #   @return [String] the stable feature id (contract vocabulary).
    # @!attribute summary
    #   @return [String] a one-line description of what it changes.
    # @!attribute severity_overrides
    #   @return [Hash{String => Symbol}] canonical rule id → the severity this feature
    #     imposes. Composed *below* the user's own `severity_overrides:` and *above* the
    #     active `severity_profile` (see {Configuration::SeverityProfile.resolve}).
    Feature = Data.define(:id, :summary, :severity_overrides) do
      def to_h
        {
          "id" => id,
          "summary" => summary,
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
        summary: "Using a value recovered from an author-declared `-> void` return in value context (an " \
                 "assignment right-hand side, a call receiver, or an argument) becomes a `:warning`. An " \
                 "explicit `-> void` is the strongest possible \"do not rely on this return\" signal, so " \
                 "the direct-dispatch case is FP-narrow; a bare-statement `void` result and a legitimate " \
                 "`top` value both stay silent. Off by default because a new required diagnostic is an " \
                 "ADR-50 WD1 compatibility change (ADR-100 WD2).",
        severity_overrides: {
          "static.value-use.void" => :warning
        }.freeze
      )
    ].freeze

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
