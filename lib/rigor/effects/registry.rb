# frozen_string_literal: true

require "yaml"

require_relative "label"

module Rigor
  module Effects
    # The effect-label vocabulary: which spellings are recognised, which have been retired, and who
    # may open a new root (ADR-103 WD2; normative in
    # `docs/type-specification/effect-labels.md`).
    #
    # The shared layer is hand-written in `data/effects/registry.yml` — Steins' v1 set verbatim,
    # Ruby's `mutate` leaves, the proposed shared core leaves and the application-meaning roots —
    # so a later slice or a plugin extends the data, not this Ruby. Extensions arrive through
    # {#with}, which is the one place root ownership is enforced.
    #
    # A Registry is a frozen value object; {#with} returns a new one rather than mutating.
    class Registry
      class Error < StandardError
      end

      # An added label whose root neither exists already nor belongs to the extender.
      class OwnershipError < Error
      end

      # An added label that is not well-formed under {Label::PATTERN}.
      class InvalidLabelError < Error
      end

      DATA_PATH = File.expand_path("../../../data/effects/registry.yml", __dir__)

      # How far a misspelling may be from a known label before {#suggest} declines to guess. Two
      # edits catches a transposition or a dropped segment character ("io.nte", "nondet.tim")
      # without proposing an unrelated label for a genuinely new spelling.
      SUGGESTION_DISTANCE_CAP = 2

      # The shared registry as shipped. Memoised: the YAML parse is a once-per-process cost, and
      # nothing consumes the registry yet, so it stays lazy rather than paying at `require "rigor"`.
      def self.default
        @default ||= load_file(DATA_PATH)
      end

      # The vocabulary one run works in: the shipped registry plus whatever `effects.labels:` opened
      # (ADR-103 WD2 / #385). The project is the one extender that may open ANY root — listing a label in
      # its own configuration is the vouching act — so this can only fail on a spelling `Configuration`
      # already rejected at load, and a failure degrades to the shipped vocabulary rather than taking the
      # run down.
      #
      # Memoised on the label list, because the answer is a frozen value object and every effects surface
      # in a run asks for the same one: the envelope pass, the unknown-label check, the snapshot header.
      # Plugin-registered roots join here in #387.
      def self.for_configuration(configuration)
        labels = configuration.effects_labels
        return default if labels.nil? || labels.empty?

        (@extended ||= {})[labels] ||= default.with(labels: labels, owner: nil)
      rescue Error
        default
      end

      # Build a registry from a registry-shaped YAML file. Missing or unreadable data degrades to
      # an empty vocabulary rather than raising, matching the built-in catalogues' posture for a
      # bare install that opted data out; every label then reads as unknown, which is fail-open.
      def self.load_file(path)
        raw = File.exist?(path) ? YAML.safe_load_file(path) : nil
        raw = {} unless raw.is_a?(Hash)
        new(
          vocabulary_version: raw.fetch("vocabulary", 0),
          labels: raw.fetch("labels", nil) || [],
          retired: raw.fetch("retired", nil) || {}
        )
      end

      attr_reader :vocabulary_version

      def initialize(vocabulary_version:, labels:, retired: {})
        @vocabulary_version = vocabulary_version
        @labels = labels.map(&:to_s).uniq.sort.freeze
        @known = build_known(@labels)
        @roots = @known.select { |label| Label.parent(label).nil? }.sort.freeze
        @retired = build_retired(retired)
        freeze
      end

      # Every declared label, sorted. Implied ancestors (`email`, because `email.send` is declared)
      # are recognised by {#known?} but are not rows of the vocabulary and are not listed here.
      attr_reader :labels

      # The roots of the vocabulary — the outermost segments {#with} treats as already owned.
      attr_reader :roots

      # Whether the vocabulary recognises `label`: an exact row, or an ancestor of one. A declared
      # `io` is recognised because `io.net` exists, so a bound may name an interior node the data
      # file never spells out on its own line.
      def known?(label)
        @known.include?(label)
      end

      # The nearest recognised label to a misspelling, within {SUGGESTION_DISTANCE_CAP} edits, or
      # `nil` when nothing is close enough. A recognised label suggests nothing — ask {#known?}
      # first.
      def suggest(label)
        return nil unless Label.valid?(label)
        return nil if known?(label)

        best = nil
        best_distance = SUGGESTION_DISTANCE_CAP + 1
        @known.each do |candidate|
          distance = levenshtein(label, candidate, best_distance)
          next unless distance < best_distance

          best = candidate
          best_distance = distance
        end
        best
      end

      # The replacement labels for a retired spelling, or `nil` when the spelling was never
      # retired. A rename or a removal bumps {#vocabulary_version} and records the old spelling
      # here so a snapshot written by an older Rigor still reads.
      def retired(label)
        @retired[label]
      end

      # A new registry carrying `labels` on top of this one.
      #
      # `owner` is the identity opening a root: a plugin id, or — for a first-party plugin that
      # models a framework — the framework root it owns. `nil` is the project, which may open any
      # root. Every added label must either descend from a root this registry already knows or
      # open a root equal to `owner`.
      def with(labels:, owner:)
        added = labels.map(&:to_s)
        added.each do |label|
          raise InvalidLabelError, "not a well-formed effect label: #{label.inspect}" unless Label.valid?(label)

          check_ownership(label, owner)
        end
        self.class.new(vocabulary_version: @vocabulary_version, labels: @labels + added, retired: @retired)
      end

      private

      def check_ownership(label, owner)
        root = Label.root(label)
        return if @roots.include?(root)
        return if owner.nil?
        return if owner == root

        raise OwnershipError,
              "#{owner.inspect} may not open the effect-label root #{root.inspect} (from #{label.inspect}); " \
              "a non-project extender opens only the root it owns"
      end

      def build_known(labels)
        known = labels.to_set
        labels.each { |label| Label.ancestors(label).each { |ancestor| known << ancestor } }
        known.freeze
      end

      def build_retired(retired)
        retired.to_h { |spelling, replacements| [spelling.to_s, Array(replacements).map(&:to_s).freeze] }.freeze
      end

      # Bounded Levenshtein. Answers `cap + 1` — "further than the cap" — as soon as the length
      # difference or a whole row of the matrix rules the candidate out, so scanning the vocabulary
      # for a suggestion stays cheap.
      def levenshtein(from, to, cap)
        beyond = cap + 1
        return beyond if (from.length - to.length).abs > cap

        previous = (0..to.length).to_a
        from.each_char.with_index(1) do |char, row|
          current = [row]
          to.each_char.with_index(1) do |other, column|
            cost = char == other ? 0 : 1
            current << [current[column - 1] + 1, previous[column] + 1, previous[column - 1] + cost].min
          end
          return beyond if current.min > cap

          previous = current
        end
        previous.last > cap ? beyond : previous.last
      end
    end
  end
end
