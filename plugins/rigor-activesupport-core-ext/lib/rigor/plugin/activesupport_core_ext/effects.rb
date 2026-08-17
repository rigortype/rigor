# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class ActivesupportCoreExt < Rigor::Plugin::Base
      # rigor-activesupport-core-ext's effect contract (ADR-103 WD10; design note § 11.2; issue #387).
      #
      # **Scope note.** This is the *impure* half of ActiveSupport only: the clock, the notification bus and
      # `CurrentAttributes`. The `%a{pure}` sweep over `blank?` / `present?` / `deep_dup` and the rest of
      # the core_ext predicate surface — the single cheapest purity win in a Rails app, per WD10 — is issue
      # #388 and lands in this plugin's shipped RBS, not here (`try` was audited and skipped: it dispatches
      # to whatever method the caller names, so its purity is a fact about the call site, not about `try`).
      # One row below (`in_time_zone_row`) is #388's own addition: `DateTime#in_time_zone` reads `Time.zone`
      # through a default argument, a gap the RBS sweep found but can only fix here.
      #
      # ## The clock
      #
      # `Time.current` and friends are `nondet.time`, plus `global.read` for the zone: `Time.zone` is
      # process state that `Time.use_zone` and the per-request `around_action` both change. The distinction
      # matters for the purity policy of ADR-103 WD9 — a method that calls `Time.current` may never have its
      # result remembered, and that is the whole reason the label exists.
      #
      # ## `CurrentAttributes`
      #
      # `Current.user` is fiber-local mutable state: `global.read` on the way in, `global.write` on the way
      # out, with `rails.current.read` / `.write` as the meaning. Rigor cannot name the attributes per app
      # — they come from an `attribute :user` macro in the project's own `Current` class — so the rows are
      # keyed on the framework base class and reach every project subclass through inheritance. `reset` and
      # `set` are named explicitly because they are the ones a reviewer looks for.
      module Effects
        TIME = "Time"
        DATE = "Date"
        DATETIME = "DateTime"
        ZONE = "Time.zone"
        CURRENT = "ActiveSupport::CurrentAttributes"
        NOTIFICATIONS = "ActiveSupport::Notifications"

        CLOCK = ["nondet.time", "global.read"].freeze
        CLOCK_NO_ZONE = ["nondet.time"].freeze
        ZONE_READ = ["global.read"].freeze
        CURRENT_READ = ["global.read", "rails.current.read"].freeze
        CURRENT_WRITE = ["global.write", "rails.current.write"].freeze
        TELEMETRY = %w[io telemetry].freeze

        # Zone-aware clock readers: they consult `Time.zone`, which is mutable process state.
        ZONED_NOW = %w[current].freeze
        # Zone-blind ones. `Time.now` / `Date.today` are already catalogue rows for core Ruby; these are the
        # ActiveSupport additions.
        ZONE_BLIND = %w[].freeze

        module_function

        def attributions
          clock_rows + zone_rows + current_rows + notification_rows + [in_time_zone_row]
        end

        def clock_rows
          [
            row(TIME, :current, CLOCK, singleton: true,
                                       why: "reads the clock AND `Time.zone`, which `Time.use_zone` and a per-request " \
                                            "`around_action` both rewrite"),
            row(DATE, :current, CLOCK, singleton: true, why: "the same, to day precision"),
            row(DATE, :yesterday, CLOCK, singleton: true, why: "`Date.current - 1`"),
            row(DATE, :tomorrow, CLOCK, singleton: true, why: "`Date.current + 1`"),
            row(DATETIME, :current, CLOCK, singleton: true, why: "the DateTime spelling of `Time.current`"),
            row("ActiveSupport::TimeZone", :now, CLOCK_NO_ZONE, singleton: true,
                                                                why: "the zone is the receiver here, so only the clock read is left"),
            row(ZONE, :now, CLOCK_NO_ZONE, why: "`Time.zone.now` — the zone is named, the clock is read"),
            row(ZONE, :today, CLOCK_NO_ZONE, why: "`Time.zone.today`")
          ] + duration_rows
        end

        # `2.days.ago` / `3.hours.from_now`. The receiver is an `ActiveSupport::Duration`; the call reads
        # the clock, which is what makes `created_at > 7.days.ago` a `nondet.time` expression and not a
        # constant.
        def duration_rows
          %w[ago until since from_now after before].map do |selector|
            row("ActiveSupport::Duration", selector, CLOCK,
                why: "`n.days.ago` and its family read the clock (and the zone) at the call — this is what " \
                     "stops a duration comparison folding to a constant")
          end
        end

        def zone_rows
          [
            row(TIME, :zone, ZONE_READ, singleton: true,
                                        why: "reads the process/fiber's current time zone, which is mutable"),
            row(TIME, :zone=, ["global.write"], singleton: true,
                                                why: "rewrites the process/fiber's time zone for everything downstream"),
            row(TIME, :use_zone, ["global.write"], singleton: true,
                                                   why: "swaps the zone around a block; the block's own origins join by containment")
          ]
        end

        # `DateTime#in_time_zone` — a gap the #388 `%a{pure}` sweep over `sig/active_support/core_ext.rbs`
        # surfaced: `in_time_zone(zone = ::Time.zone)` reads `Time.zone` through its own default argument
        # whenever the caller doesn't pass one explicitly, so it cannot be annotated `%a{pure}` there. It
        # belongs here rather than in the RBS because the label is `global.read` alone (not the
        # `nondet.time` + `global.read` pair `CLOCK` carries) — `in_time_zone` converts an already-fixed
        # instant into a zone, it does not read the clock itself.
        def in_time_zone_row
          row("DateTime", :in_time_zone, ZONE_READ,
              why: "the default argument reads `Time.zone` when the caller doesn't name one explicitly")
        end

        def current_rows
          [
            row(CURRENT, :set, CURRENT_WRITE, singleton: true,
                                              why: "writes fiber-local request state that every later read in the request sees"),
            row(CURRENT, :reset, CURRENT_WRITE, singleton: true, why: "clears the same fiber-local state"),
            row(CURRENT, :attributes, CURRENT_READ, singleton: true, why: "reads the whole bag"),
            row(CURRENT, :attributes=, CURRENT_WRITE, singleton: true, why: "replaces the whole bag"),
            row(CURRENT, :instance, CURRENT_READ, singleton: true,
                                                  why: "materialises the per-fiber instance the accessors read through")
          ]
        end

        def notification_rows
          [
            EffectAttribution.new(
              receiver: NOTIFICATIONS, method: :instrument, labels: TELEMETRY, singleton: true,
              discharge: true, taint: "opaque-callable",
              why: "publishes to the notification bus — `io` because a subscriber may do anything and " \
                   "`telemetry` because that is the meaning. The taint is the honest half: the SUBSCRIBERS " \
                   "are registered at runtime and the analyzer cannot see them, so the summary reads " \
                   "'this much, and possibly more'"
            ),
            row(NOTIFICATIONS, :publish, TELEMETRY, singleton: true, why: "the bare publish"),
            row(NOTIFICATIONS, :subscribe, ["mutate.static"], singleton: true,
                                                              why: "registers a subscriber on process-global state")
          ]
        end

        def row(receiver, selector, labels, why:, singleton: false)
          EffectAttribution.new(receiver: receiver, method: selector, labels: labels,
                                singleton: singleton, discharge: true, why: why)
        end
      end
    end
  end
end
