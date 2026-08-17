# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Actionmailer < Rigor::Plugin::Base
      # rigor-actionmailer's effect contract (ADR-103 WD10; design note § 11.2; issue #387).
      #
      # ActionMailer is the clearest case in Rails of a lazy builder followed by a transport, and the
      # design note's deferred-execution rule reads it straight off the syntax:
      #
      #     UserMailer.welcome(user).deliver_now
      #     └──────── builder ─────┘└─ the effect ┘
      #
      # `UserMailer.welcome(u)` runs the mailer method and returns a `MessageDelivery` that has sent
      # nothing. So it is an **edge** into `UserMailer#welcome` (whose own body may well read the
      # database) and contributes no transport of its own. `deliver_now` is the send. `deliver_later`
      # enqueues, which is ActiveJob's row plus the mail meaning — `email.send` still belongs there,
      # because the mail WILL go out and a policy that forbids sending mail from a presenter means to
      # forbid both spellings.
      #
      # The `on_result:` rows are what make this work on the idiom people actually write: the
      # `MessageDelivery` in the middle has no type the project declares, but the class that produced it
      # is written right there.
      module Effects
        BASE = "ActionMailer::Base"
        DELIVERY = "ActionMailer::MessageDelivery"

        NOW = ["io", "email.send", "rails.actionmailer.deliver"].freeze
        LATER = ["io", "email.send", "rails.actionmailer.deliver", "rails.activejob.enqueue",
                 "job.enqueue"].freeze

        module_function

        def attributions
          rows(:deliver_now, NOW,
               why: "the SMTP / API round trip itself — `io` because the delivery method is configured " \
                    "per environment and is statically unknowable, `email.send` because that is what a " \
                    "policy names") +
            rows(:deliver_now!, NOW, why: "`deliver_now!` is `deliver_now` ignoring the perform-deliveries " \
                                          "setting; the same send") +
            rows(:deliver_later, LATER,
                 why: "enqueues a delivery job: the enqueue rows, plus `email.send` — the mail goes out, " \
                      "and a policy forbidding mail from this layer means both spellings") +
            rows(:deliver_later!, LATER, why: "`deliver_later!` raises rather than serialising a missing " \
                                              "record; the same enqueue")
        end

        # Each selector twice: once on a `MessageDelivery` receiver the typer managed to name, and once on
        # the RESULT of a call to the mailer class, which is the spelling in every Rails codebase.
        def rows(selector, labels, why:)
          [
            EffectAttribution.new(receiver: DELIVERY, method: selector, labels: labels, discharge: true,
                                  why: why),
            EffectAttribution.new(receiver: BASE, method: selector, labels: labels, on_result: true,
                                  discharge: true,
                                  why: "#{why} Matched on the result of `UserMailer.welcome(u)`, whose " \
                                       "MessageDelivery has no type the project declares.")
          ]
        end

        def edges
          [
            EffectEdge.new(
              receiver: BASE, target: :mailer_body,
              why: "`UserMailer.welcome(u)` instantiates the mailer and runs `#welcome` — synchronously, " \
                   "in this process, before any delivery is attempted. The mailer body's own effects " \
                   "(the records it reads to build the mail) belong to the caller"
            )
          ]
        end

        def entry_points
          [
            EffectEntryPoints.new(
              name: "rails-mailers", globs: ["app/mailers/**/*.rb"],
              why: "mailer actions — invoked by the framework through the class-method mapping"
            )
          ]
        end
      end
    end
  end
end
