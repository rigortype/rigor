# frozen_string_literal: true

require_relative "unknown_label_report"

module Rigor
  module Effects
    # Turns the declarations a run carries into `effect.unknown-label` findings (ADR-103 WD1 / WD14;
    # #384). Pure: it reads envelopes and config values and answers value objects, never diagnostics
    # and never the filesystem — positioning the finding is the caller's job, because only the caller
    # knows whether a `virtual:` buffer has to be mapped back to the `.rb` the author wrote in.
    #
    # Two producers today, one shape:
    #
    # - {.for_envelopes} — every `%a{pure}` / `%a{rigor:v1:effect …}` the envelope scanner read, in
    #   `.rbs` or through rbs-inline. One finding per (declaration, unrecognised token); a
    #   `def self?.x` member declares two keys off ONE annotation, so findings are deduplicated by
    #   where they were written rather than by which method they bind.
    # - {.for_config} — a `.rigor.yml` label list: `effects.tolerated:`, `effects.labels:`, each
    #   `envelopes[].effect` and each `attribution:` value. The key path is a parameter rather than a
    #   literal precisely because there are four of them and each names a different place to edit.
    module UnknownLabelCheck
      # `location` is the `path:line` the declaration was written at, or nil for a config value —
      # the caller resolves both. `spelling` is the author's own annotation text, which is also how a
      # finding read out of a synthesized buffer is found again in the Ruby source.
      Finding = Data.define(:token, :subject, :consequence, :location, :spelling, :report) do
        def message = report.message(subject: subject, consequence: consequence)
      end

      ENVELOPE_CONSEQUENCE = "the annotation now bounds nothing"

      module_function

      def for_envelopes(method_envelopes:, class_envelopes:, registry:)
        seen = {}
        declarations(method_envelopes, class_envelopes).each do |envelope|
          envelope.unknown_labels.each do |token|
            report = UnknownLabelReport.for(
              token: token, registry: registry, siblings: envelope.declared_labels
            )
            next if report.nil?

            seen[[envelope.location, envelope.spelling, token]] ||= envelope_finding(envelope, token, report)
          end
        end
        seen.values
      end

      # @rbs labels: Array[String] -- The list as written, in source order.
      # @rbs key_path: String -- The `.rigor.yml` key, for the message (`effects.tolerated`).
      # @rbs consequence: String -- What the degradation cost, for the message.
      def for_config(labels:, key_path:, consequence:, registry:)
        tokens = Array(labels).map(&:to_s)
        tokens.filter_map do |token|
          report = UnknownLabelReport.for(token: token, registry: registry, siblings: tokens)
          next if report.nil?

          Finding.new(
            token: token, subject: "`#{key_path}:` in .rigor.yml", consequence: consequence,
            location: nil, spelling: nil, report: report
          )
        end
      end

      # Method-level declarations first, so a method that also carries a class-level bound reports
      # against its own annotation rather than against the distributed one.
      def declarations(method_envelopes, class_envelopes)
        method_envelopes.values + class_envelopes.values
      end

      def envelope_finding(envelope, token, report)
        Finding.new(
          token: token, subject: "Effect envelope on #{envelope.owner_key}",
          consequence: ENVELOPE_CONSEQUENCE, location: envelope.location,
          spelling: envelope.spelling, report: report
        )
      end

      private_class_method :declarations, :envelope_finding
    end
  end
end
