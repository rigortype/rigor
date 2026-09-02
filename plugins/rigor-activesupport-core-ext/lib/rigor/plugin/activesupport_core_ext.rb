# frozen_string_literal: true

require "rigor/plugin"

require_relative "activesupport_core_ext/effects"

module Rigor
  module Plugin
    # ADR-25 — very nearly a pure RBS-bundle plugin. It emits no diagnostic and declares no producer; its
    # main contribution is the manifest's `signature_paths: ["sig"]`, which declares the bundled
    # ActiveSupport `core_ext` RBS directory. `Plugin::Loader` resolves that directory against this gem's
    # root and `Environment.for_project` merges it into the RBS environment, so the ActiveSupport
    # core-extension selectors (`3.days`, `"x".squish`, `Time.current`, …) resolve.
    #
    # The one exception is the {DURATION_MULTIPLIERS} pair of `dynamic_return` rules, which give `1.day` /
    # `5.minutes` an `ActiveSupport::Duration` nominal and keep the arithmetic around it honest. They
    # cannot live in the RBS bundle; see the comment on that constant for why.
    #
    # Issue #632 — `sig/active_support/core_ext.rbs` now ALSO declares `ActiveSupport::Duration` itself
    # (the reader surface: `ago`/`until`/`since`/`from_now`/`before`/`after`, `to_i`/`in_seconds`, `to_f`,
    # `in_minutes`/`in_hours`/`in_days`/`in_weeks`/`in_months`/`in_years`, `iso8601`, `parts`), which is
    # what lets `30.minutes.ago.iso8601` / `1.day.to_i * 2` resolve past the first reader. That is new: the
    # multiplier fix above went out of its way NOT to name the class (naming it makes it RBS-known, and a
    # known class with an incomplete signature turns every member the declaration omits into a false
    # `call.undefined-method` — Duration forwards everything else to the wrapped numeric via
    # `method_missing`). Declaring it now is safe because `ActiveSupport::Duration` is protected TWICE:
    # this manifest's own `open_receivers:` (ADR-26, below — the mechanism `rigor-activerecord` uses for
    # `ActiveRecord::Relation`) covers the plugin-loaded path, and
    # `Rigor::Analysis::CheckRules::GEM_OVERLAY_OPEN_RECEIVERS` covers the auto-applied
    # `data/gem_overlay/activesupport/core_ext.rbs` twin (issue #449's overlay-has-no-manifest gap — see that
    # constant's comment). Either alone would keep `call.undefined-method` from ever firing against a
    # Duration receiver; both exist because a plugin manifest cannot protect a receiver an unrelated,
    # manifest-less RBS file also declares.
    #
    # Activate it like any plugin — no path, no vendoring:
    #
    #   # .rigor.yml
    #   plugins:
    #     - rigor-activesupport-core-ext
    #
    # Coverage scope and rationale: see `README.md` in this gem.
    class ActivesupportCoreExt < Rigor::Plugin::Base
      manifest(
        id: "activesupport-core-ext",
        # Bumped 2026-09-02 (#632) — `ActiveSupport::Duration`'s reader surface (`ago`/`to_i`/`iso8601`/…)
        # is now declared, open_receivers-protected; see the class comment above.
        version: "0.4.0",
        description: "RBS bundle for the most-frequently-flagged ActiveSupport core_ext extensions, " \
                     "plus the `ActiveSupport::Duration` type of the numeric time multipliers and its " \
                     "reader surface.",
        signature_paths: ["sig"],
        # ADR-26 — `ActiveSupport::Duration` forwards any method its own class doesn't define to the
        # wrapped numeric via `method_missing` (audited against ActiveSupport 8.1.3.1's
        # `lib/active_support/duration.rb`), so `sig/`'s necessarily-partial declaration of it must not let
        # `call.undefined-method` fire against it. Distinct from the RECEIVER-side FP the multiplier
        # `dynamic_return` gate guards (`Time#day` vs `Duration#day`, in the class comment above) — this is
        # the class's OWN unenumerable member set.
        open_receivers: ["ActiveSupport::Duration"],
        # ADR-103 WD10 (#387) — the IMPURE half of ActiveSupport: the clock, the notification bus and
        # `CurrentAttributes`. The `%a{pure}` sweep over the predicate surface is issue #388 and lands in
        # `sig/`, not here. See {Effects}.
        effect_root: "rails",
        effect_labels: %w[rails.current.read rails.current.write],
        effect_attributions: Effects.attributions
      )

      # Issue #534 item 3 — `core_ext/numeric/time`'s Duration multipliers. The 2026-09-01 corpus sweep
      # measured ~265 mastodon sites on these, every one of them `Dynamic[top]` with cause
      # `explicit_untyped`: the RBS bundle declares them `() -> untyped` so that `1.day` merely *resolves*,
      # and the value it produces then carries nothing.
      #
      # ## Why this is a `dynamic_return` and not an RBS return type
      #
      # The obvious fix — changing `core_ext.rbs`'s `def day: () -> untyped` to
      # `() -> ActiveSupport::Duration` — is not available, and the reason is the whole design here. RBS
      # cannot name a class it does not declare, so that edit forces the bundle to declare
      # `ActiveSupport::Duration` too, which makes the class RBS-KNOWN — and a known class with an
      # incomplete signature is worse than no class at all: `call.undefined-method` stops declining at
      # `Rigor::Reflection.rbs_class_known?`, so every member the declaration omits becomes a false
      # positive on working code. `Duration`'s real surface is `method_missing`-forwarded to the wrapped
      # numeric plus `ago` / `since` / `from_now` / `until` / `before` / `after` / `in_*` / `iso8601` and
      # every `Numeric` operator, so "omits a member" is guaranteed. The contribution tier sits ABOVE
      # `RbsDispatch` (`MethodDispatcher#resolve`), so declaring the multiplier in RBS and typing it here
      # is not a contradiction: the RBS declaration is what makes `1.day` resolve at all, and this supplies
      # the answer the declaration deliberately withholds.
      #
      # ## The receiver gate is the FP boundary
      #
      # `day`, `month`, `year`, `hour`, `minute`, `second` and `week` are all real methods on `Time` and
      # `Date` that return an `Integer`, so a name-only rule would silently retype `created_at.day` from
      # `Integer` to a Duration — a wrong precise type on a hot core method. The gate therefore admits only
      # a receiver Rigor has actually proven numeric, including the folded literal carriers (`Constant[1]`,
      # `IntegerRange`) which is what `1.day` is at the call site, and declines on everything else,
      # `Dynamic` included. Declining on `Dynamic` costs a few sites on untyped receivers and is what keeps
      # a `record.days` on some project's own object untouched.
      DURATION_MULTIPLIERS = %i[
        second seconds minute minutes hour hours day days week weeks
        fortnight fortnights month months year years
      ].freeze

      # The nominal every multiplier returns. It is a *lenient* nominal: the site becomes a concrete
      # receiver that `coverage --protection` counts, and `call.undefined-method` never fires against it
      # (ADR-26 `open_receivers:` below) regardless of what its RBS does or doesn't enumerate. Issue #632
      # gave `ActiveSupport::Duration` an actual (partial) RBS declaration — `sig/active_support/
      # core_ext.rbs`'s reader surface, `to_i` / `in_seconds` / `to_f` / the `in_minutes` family / `iso8601`
      # / `parts` — so THOSE now resolve precisely instead of to `Dynamic`. `ago` / `until` / `before` /
      # `since` / `from_now` / `after` stay undeclared on purpose (issue #659, blocked on #658: typing them
      # needs the Rails `Time` instance surface first) and the rest of Duration's real API — the arithmetic
      # operators, `==`, anything `method_missing` forwards to the wrapped numeric — was simply never in
      # scope. Every one of those still resolves lenient-to-`Dynamic` rather than to a diagnostic.
      DURATION_NOMINAL = "ActiveSupport::Duration"

      # The receiver class names the multipliers are real methods on. `Numeric` is included for a receiver
      # typed at the abstract class (a `Numeric` parameter); `Rational` / `BigDecimal` are not, because the
      # RBS bundle does not declare the multipliers on them, so `2r.days` does not resolve in the first
      # place and typing its result would be a claim about a call Rigor cannot see.
      DURATION_RECEIVER_CLASSES = %w[Integer Float Numeric].freeze

      dynamic_return methods: DURATION_MULTIPLIERS do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.receiver # `day` with no receiver is somebody's own method
        next nil unless call_node.arguments.nil?
        next nil unless call_node.block.nil?
        next nil unless numeric_receiver?(scope&.type_of(call_node.receiver))

        Rigor::Type::Combinator.nominal_of(DURATION_NOMINAL)
      end

      # ## Duration arithmetic — a correction, not a feature
      #
      # Typing the multiplier alone REGRESSES three shapes, measured on a fixture before this rule existed.
      # A Duration is an ordinary argument to the core operators, and the overload selector has to choose
      # among `Time#-`'s `(Time) -> Float` / `(Numeric) -> Time` with an argument whose class it has no RBS
      # for. Given `Dynamic[top]` — the pre-#534 answer — it widened to the union of the returns and stayed
      # lenient; given a *named* class it commits, and it commits wrong:
      #
      #     Time.now - 30.minutes    before: Dynamic[Float | Time]     after (no rule): Float
      #     2 * 1.day                before: Dynamic[BigDecimal | …]   after (no rule): Integer
      #     3 + 1.day                before: Dynamic[BigDecimal | …]   after (no rule): Integer
      #     Date.today - 1.week      before: Dynamic[Date | Rational]  after (no rule): Rational
      #
      # Each of those is a wrong precise type, and each turns the next line into a false positive:
      # `(Time.current - 30.minutes).beginning_of_day` became `undefined method 'beginning_of_day' for
      # Float`, `(2 * 1.day).ago` became one for Integer, `(Date.today - 1.week).year` one for Rational
      # (5/5 measured). `Time.current - 1.day` is ordinary Rails, so shipping the multipliers without this
      # rule would trade ~265 typed sites for diagnostics on working code — the trade AGENTS.md forbids.
      # The rule restores the runtime answer at each of those sites:
      #
      # - `Time`/`DateTime` ± Duration → the receiver's own class. Rails' `plus_with_duration` /
      #   `minus_with_duration` return `other.since(self)` / `other.until(self)`, i.e. the receiver kind.
      # - `Date` ± Duration → `Date | Time`, and the union is the honest answer rather than a hedge:
      #   `Duration#since` returns a Date for a date-part duration and a Time for a sub-day one, so
      #   `Date.today + 1.day` really is a Date and `Date.today + 1.hour` really is a Time. Rigor's union
      #   receiver declines a method that only one arm has (measured: `.hour` on `Date | Time` is silent),
      #   so the union costs nothing in false positives while keeping both arms named.
      # - Numeric ± Duration, and Numeric * Duration → Duration. `Duration#coerce` wraps the numeric in a
      #   `Duration::Scalar`, so `2 * 1.day` is a two-day Duration, not an Integer.
      # - Duration ± Duration and Duration * Numeric → Duration. Not a correction (the RBS-less receiver
      #   was already lenient) but the same contract, and it is what carries a `1.day + 1.hour` chain.
      #
      # `/` is deliberately absent: `1.day / 2` is a Duration but `1.day / 1.hour` is a plain `24`, and the
      # answer depends on the operand kind in a way this table would have to guess at. So is
      # `Duration * Duration` — not a quantity Rails promises anything about. So is a Duration RECEIVER
      # with a `Time` / `DateTime` / `Date` argument (#588): `30.minutes + Time.now` raises, under every
      # operator — the table types values, and a crashing expression has none.

      # Receiver class → what `receiver <op> duration` is. `Time` / `DateTime` keep their own kind; `Date`
      # widens to the two kinds `Duration#since` can produce; a numeric or another Duration is a Duration.
      DURATION_ARITHMETIC_SELF_KINDS = %w[Time DateTime].freeze
      DURATION_ARITHMETIC_NUMERIC_KINDS = %w[Integer Float Numeric].freeze
      DURATION_ARITHMETIC_DATE_KINDS = %w[Date Time].freeze

      # The operand kinds whose arithmetic with a Duration is itself a Duration — on BOTH sides of the
      # operator. See {#duration_valued_pair?} for why the argument side is checked too.
      DURATION_VALUED_OPERAND_KINDS = %i[duration numeric].freeze

      dynamic_return methods: %i[+ - *] do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)

        argument = duration_arithmetic_argument(call_node)
        next nil if argument.nil?

        # The ARGUMENT is checked before the receiver: it is the cheaper of the two on the overwhelmingly
        # common shapes (`i + 1`, `n * 2`), and a call with no Duration operand must cost as little as
        # possible — this rule is consulted on every `+` / `-` / `*` in the project. The early exit is
        # what makes the ordering worth anything: an argument that is no Duration operand at all
        # (`"a" + b`, `list + other`) declines here and never types its receiver on this rule's behalf.
        argument_kind = duration_operand_kind(scope&.type_of(argument))
        next nil if argument_kind.nil?

        receiver_kind = duration_operand_kind(scope&.type_of(call_node.receiver))
        next nil if receiver_kind.nil?

        duration_arithmetic_result(call_node.name, receiver_kind, argument_kind)
      end

      # ADR-88 WD1 — both tables are static and the RBS bundle ships with the gem; nothing here reads a
      # project file, so a project enabling this plugin stays incremental-capable.
      def incremental_state_fingerprint
        "static-duration-multipliers"
      end

      private

      # True only for a receiver Rigor has actually proven numeric. `Constant` covers the literal form the
      # idiom is written in (`1.day`); `IntegerRange` covers a refined integer; `Nominal` covers a value
      # typed at the class. Everything else — `Dynamic`, a user nominal, a union — declines.
      def numeric_receiver?(type)
        case type
        when Rigor::Type::Constant then type.value.is_a?(Integer) || type.value.is_a?(Float)
        when Rigor::Type::IntegerRange then true
        when Rigor::Type::Nominal then DURATION_RECEIVER_CLASSES.include?(type.class_name)
        else false
        end
      end

      # The single positional argument of a binary operator call, or nil for every other shape. Purely
      # syntactic, so it runs before any type is computed.
      def duration_arithmetic_argument(call_node)
        arguments = call_node.arguments&.arguments
        return nil unless arguments&.size == 1

        argument = arguments.first
        return nil if argument.is_a?(Prism::SplatNode) || argument.is_a?(Prism::KeywordHashNode)

        argument
      end

      # The operand's role in Duration arithmetic — `:duration`, `:numeric`, or its own class name for the
      # date/time kinds — or nil for everything else, which is what declines the rule. Note the exact
      # class-name match on the date/time kinds: a `Time` subclass is not retyped as its parent.
      def duration_operand_kind(type)
        case type
        when Rigor::Type::Constant
          :numeric if type.value.is_a?(Integer) || type.value.is_a?(Float)
        when Rigor::Type::IntegerRange then :numeric
        when Rigor::Type::Nominal then duration_operand_kind_for_class(type.class_name)
        end
      end

      def duration_operand_kind_for_class(class_name)
        return :duration if class_name == DURATION_NOMINAL
        return :numeric if DURATION_ARITHMETIC_NUMERIC_KINDS.include?(class_name)
        return :date if class_name == "Date"

        class_name if DURATION_ARITHMETIC_SELF_KINDS.include?(class_name)
      end

      # The runtime answer for `receiver <op> argument`, or nil when the pair is not one this rule speaks
      # for. At least one operand must be a Duration — otherwise the call is ordinary arithmetic and keeps
      # whatever answer it always had (`1 + 1`, `Time - Time`, `"a" + "b"`).
      def duration_arithmetic_result(operator, receiver_kind, argument_kind)
        return nil unless receiver_kind == :duration || argument_kind == :duration

        if DURATION_ARITHMETIC_SELF_KINDS.include?(receiver_kind)
          # `Time`/`DateTime` ± Duration → the receiver's own kind. Multiplication is not defined.
          return Rigor::Type::Combinator.nominal_of(receiver_kind) if operator != :*
        elsif receiver_kind == :date
          # `Date` ± Duration → whichever kind the duration's parts make of it.
          return date_arithmetic_union if operator != :*
        elsif duration_valued_pair?(operator, receiver_kind, argument_kind)
          # Duration ± Duration, Duration ± numeric, numeric ± Duration, and the `*` forms of each: a
          # Duration, via `Duration#coerce`'s `Duration::Scalar` wrapper.
          return Rigor::Type::Combinator.nominal_of(DURATION_NOMINAL)
        end
        nil
      end

      # The pairs whose value is a Duration: a Duration or numeric on BOTH sides, minus `Duration *
      # Duration` (not a quantity Rails promises). The argument side of the check is #588 — a Duration
      # receiver with a `Time` / `DateTime` / `Date` argument is an expression that RAISES:
      # `30.minutes + Time.now` adds the Time to the seconds part and `Integer#+` cannot coerce it
      # (TypeError), `30.minutes - Time.now` sends `-@` to the Time (NoMethodError), and `*` is a
      # TypeError from `Duration#calculate` — 7/7 shapes measured on ActiveSupport 8.1. Claiming
      # `Duration` there would type crashing code; declining leaves the RBS-less receiver lenient, which
      # is the honest answer for an expression that has no value.
      def duration_valued_pair?(operator, receiver_kind, argument_kind)
        return false unless DURATION_VALUED_OPERAND_KINDS.include?(receiver_kind)
        return false unless DURATION_VALUED_OPERAND_KINDS.include?(argument_kind)

        !(operator == :* && receiver_kind == :duration && argument_kind == :duration)
      end

      def date_arithmetic_union
        Rigor::Type::Combinator.union(
          *DURATION_ARITHMETIC_DATE_KINDS.map { |name| Rigor::Type::Combinator.nominal_of(name) }
        )
      end
    end

    Rigor::Plugin.register(ActivesupportCoreExt)
  end
end
