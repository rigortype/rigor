# frozen_string_literal: true

module Rigor
  module Analysis
    class Runner
      # How an effect-envelope finding is worded (ADR-103 WD14; #383 / #386).
      #
      # One module for both contracts, because their messages are one sentence with a swapped middle:
      # `effect.envelope-exceeded` names the bound the method carries, `effect.liskov-widened` names the
      # bound it inherits, and both end by naming the label that escaped. Keeping the two here is what
      # stops them drifting into two dialects of the same explanation — and what keeps
      # {EffectEnvelopePass} about *when* a finding is produced rather than about how it reads.
      #
      # The shape a reviewer can act on without re-running anything: what the method does, the shortest
      # route to whatever proves it, the author's own spelling of the bound quoted back, and where that
      # bound was written.
      module EnvelopeMessages
        module_function

        # `Effects::EnvelopeCheck::Finding` — a method against its own bound.
        def exceeded(finding)
          "Method #{finding.key} performs #{finding.label}#{explanation(finding)}, but is declared " \
            "#{finding.envelope.spelling}#{declared_at(finding.envelope)}, so #{finding.label} exceeds " \
            "the envelope."
        end

        # `Effects::LiskovCheck::Finding` — an override against the bound it inherits. Two variants of
        # one sentence, and which one a reader gets says which comparison produced the finding: what the
        # override *does* against the inherited bound, or what it *declares* against it. Both name the
        # ancestor's declaration, because that is where the fix usually goes.
        def liskov(finding)
          "Method #{finding.key} #{liskov_subject(finding)}, but overrides #{finding.ancestor_key}, " \
            "which is declared #{finding.ancestor_envelope.spelling}" \
            "#{declared_at(finding.ancestor_envelope)}, so #{finding.label} exceeds the inherited envelope."
        end

        def liskov_subject(finding)
          own = finding.own_envelope
          return "is declared #{own.spelling}#{declared_at(own)}" if own

          "performs #{finding.label}#{explanation(finding)}"
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
      end
    end
  end
end
