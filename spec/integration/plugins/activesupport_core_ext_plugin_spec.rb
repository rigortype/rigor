# frozen_string_literal: true

# Integration spec for `plugins/rigor-activesupport-core-ext/`.
#
# ADR-25 — the bundle is a pure RBS-bundle plugin: its manifest declares `signature_paths: ["sig"]` and the
# plugin loader feeds that directory into the RBS environment. This spec proves the end-to-end path: with the
# plugin active, ActiveSupport `core_ext` selectors type-check instead of producing `call.undefined-method` diagnostics.

require "spec_helper"

unless defined?(AS_CORE_EXT_PLUGIN_LIB)
  AS_CORE_EXT_PLUGIN_LIB = File.expand_path(
    "../../../plugins/rigor-activesupport-core-ext/lib", __dir__
  )
end
$LOAD_PATH.unshift(AS_CORE_EXT_PLUGIN_LIB) unless $LOAD_PATH.include?(AS_CORE_EXT_PLUGIN_LIB)
require "rigor-activesupport-core-ext"

RSpec.describe "plugins/rigor-activesupport-core-ext" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ActivesupportCoreExt }

  it "is a pure RBS-bundle plugin — the manifest declares signature_paths" do
    expect(plugin_class.manifest.signature_paths).to eq(["sig"])
  end

  it "declares ActiveSupport::Duration open (#632), matching rigor-activerecord's Relation pattern" do
    expect(plugin_class.manifest.open_receivers).to eq(["ActiveSupport::Duration"])
  end

  it "contributes the core_ext sig so ActiveSupport selectors type-check" do
    source = <<~RUBY
      a = 3.days
      b = "user_account".camelize
      c = Time.current
      d = "  x   y  ".squish
      e = Array.wrap(nil)
      f = { "k" => 1 }.symbolize_keys
      g = nil.blank?
    RUBY
    result = run_plugin(source: source)
    undefined = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
    expect(undefined).to be_empty
  end

  it "declares the GitLab-surfaced String / Object / Date / ERB extensions in its RBS bundle" do
    # `upcase_first` / `remove` / `in?` fired `undefined-method` on GitLab once AR typed real String
    # columns; `titlecase` / `dasherize` / `advance` / `all_day` / `Date#to_time(form)` /
    # `ERB::Util.html_escape_once` are the activesupport-core-ext gaps the survey adjudicated. The bundle
    # is validated against `rbs` by the `check-plugins` gate; this locks the specific additions.
    rbs = File.read(
      File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs", __dir__)
    )
    %w[upcase_first remove titlecase dasherize advance all_day].each do |method|
      expect(rbs).to match(/def #{method}:/), "expected RBS to declare `#{method}`"
    end
    expect(rbs).to include("def in?:")
    # `| ...` and not a plain declaration — see the collision guard below (#437).
    expect(rbs).to include("def to_time: (?Symbol form) -> Time | ...")
    expect(rbs).to include("def self.html_escape_once:")
  end

  # Issue #437. A method the plugin declares in full while a signature source ALREADY in the environment
  # declares it too makes `RBS::DefinitionBuilder` raise `DuplicatedMethodDefinitionError`. Rigor fails
  # soft, so nothing crashes — the whole class just degrades to `Dynamic[top]`, and real methods and typos
  # alike stop being witnessed. `Date#to_time` sat in that state against rbs's bundled `stdlib/date` and
  # took `Date` and `DateTime` down with it for every project following the plugin chapter.
  #
  # The collision is INVISIBLE to a fixture that loads only one signature source, which is exactly how it
  # survived: the plugin's own `sig/` parses and validates fine on its own. So the guard below builds the
  # real environment — `DEFAULT_LIBRARIES` (where rbs's `stdlib/date` enters) PLUS the plugin's `sig/` —
  # and asserts every definition in it builds. That is the shape that catches the NEXT one too.
  describe "collisions against rbs's bundled stdlib (#437)" do
    # Exactly what `Environment.for_project` assembles for a project with the plugin active: it merges
    # `DEFAULT_LIBRARIES` into every run unconditionally, then appends the registry's plugin sig paths.
    # The ADR-72 ActiveSupport gem overlay is deliberately absent — `GEM_OVERLAY_PLUGIN_IDS` stands it
    # down whenever this plugin is loaded, so the two never co-occur.
    let(:env) do
      Rigor::Environment::RbsLoader.build_env_for(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES,
        signature_paths: [File.expand_path("../../../plugins/rigor-activesupport-core-ext/sig", __dir__)]
      )
    end

    let(:builder) { RBS::DefinitionBuilder.new(env: env) }

    it "builds Date and DateTime rather than collapsing them" do
      %w[::Date ::DateTime].each do |name|
        type_name = RBS::TypeName.parse(name)

        expect(builder.build_instance(type_name)).not_to be_nil
        expect(builder.build_singleton(type_name)).not_to be_nil
      end
    end

    # The reason the row is an overload continuation instead of a deletion: dropping it would have left
    # only the stdlib arity, and `date.to_time(:utc)` — correct Rails code — would draw an arity
    # diagnostic. Both arities must resolve, and the ActiveSupport one must keep its `%a{pure}` envelope.
    it "resolves both arities of Date#to_time, with %a{pure} on the ActiveSupport overload" do
      method = builder.build_instance(RBS::TypeName.parse("::Date")).methods[:to_time]
      arities = method.method_types.map { |mt| mt.type.optional_positionals.size }

      expect(arities).to contain_exactly(0, 1)
      expect(method.defs.first.member.annotations.map(&:string)).to include("pure")
    end

    # The sweep: no class or module anywhere in the plugin-active environment may fail to build. This is
    # what generalises past `Date` — every other row in the bundle is checked against rbs's stdlib here,
    # not one at a time as each collapse gets noticed in the field.
    it "builds every class and module in the plugin-active environment" do
      failures = env.class_decls.each_key.with_object([]) do |name, acc|
        builder.build_instance(name)
        builder.build_singleton(name)
      rescue StandardError => e
        acc << "#{name}: #{e.class}: #{e.message.lines.first.to_s.strip}"
      end

      expect(failures).to be_empty
    end

    # End-to-end, through a real run: a degraded class witnesses NOTHING, so a typo on a `Date` receiver
    # going unreported is the observable symptom. This example fails if the plain declaration returns.
    it "still witnesses a typo on a Date receiver" do
      result = run_plugin(source: "Date.today.no_such_method_here\nDateTime.now.no_such_method_here\n")
      undefined = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }

      expect(undefined.size).to eq(2)
    end
  end

  # Issue #658. `Time` is a CORE class, RBS-known and therefore CLOSED, and this bundle declared only the
  # `core_ext/time/calculations` slice of what ActiveSupport adds to it. On a closed receiver an OMISSION
  # is a false positive on correct Rails code exactly as much as a wrong return type is, so the whole
  # `DateAndTime::Calculations` / `time/conversions` / `date_and_time/zones` surface is declared now,
  # audited against the vendored activesupport-8.1.3.1 sources.
  #
  # The must-not-fire half alone would pass vacuously if the class had collapsed to `Dynamic[top]` (the
  # #437 failure above), so every example here is paired with a positive: either a `dump_type` that has to
  # read a real type, or the still-witnessed typo below.
  describe "the Rails Time instance surface (#658)" do
    def dumps(result)
      result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    end

    def undefined_methods(result)
      result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
    end

    # The nine calls the issue opened on, verbatim. Each one is `error: undefined method … for Time` on
    # master with this plugin loaded.
    let(:issue_source) do
      <<~RUBY
        c = Time.current
        c.to_fs(:db)
        c.to_formatted_s(:db)
        c.at_beginning_of_hour
        c.middle_of_day
        c.in_time_zone
        c.past?
        c.future?
        c.today?
        c.formatted_offset
      RUBY
    end

    it "reports nothing for the nine Rails Time calls the issue opened on" do
      expect(undefined_methods(run_plugin(source: issue_source))).to be_empty
    end

    # The must-still-succeed half, and it is the one that matters: the FP could equally have been "fixed"
    # by making `Time` an open receiver, which would take the genuine diagnostic with it project-wide.
    it "still witnesses a genuinely undefined method on a Time receiver" do
      result = run_plugin(source: "#{issue_source}c.definitely_not_a_method\n")

      expect(undefined_methods(result).size).to eq(1)
      expect(undefined_methods(result).first).to include("definitely_not_a_method")
    end

    it "resolves the new surface to real types rather than leaving it Dynamic" do
      source = <<~RUBY
        t = Time.current
        Rigor.dump_type(t.to_fs(:db))
        Rigor.dump_type(t.formatted_offset)
        Rigor.dump_type(t.middle_of_day)
        Rigor.dump_type(t.quarter)
        Rigor.dump_type(t.seconds_since_midnight)
        Rigor.dump_type(t.seconds_until_end_of_day)
        Rigor.dump_type(t.all_quarter)
        Rigor.dump_type(t.days_ago(3).beginning_of_quarter.to_fs(:db))
      RUBY

      expect(dumps(run_plugin(source: source))).to eq(
        [
          "dump_type: String", "dump_type: String", "dump_type: Time", "dump_type: Integer",
          "dump_type: Float", "dump_type: Integer", "dump_type: Range[Time]", "dump_type: String"
        ]
      )
    end

    # `at_beginning_of_week` / `at_end_of_week` are `alias`es of `beginning_of_week` / `end_of_week`, so
    # they take the same optional `start_day`. Declared zero-arity, the second and third lines below were
    # `call.wrong-arity` on correct Rails code — an FP the #658 audit turned up in rows that were already
    # here rather than in the missing ones. The last line is the must-still-fire half: a genuinely
    # over-applied zero-arity method still reports, so this is not the receiver going lenient.
    it "takes the optional start_day on the at_-prefixed week aliases, and still catches a real overrun" do
      source = <<~RUBY
        t = Time.current
        Rigor.dump_type(t.at_beginning_of_week)
        Rigor.dump_type(t.at_beginning_of_week(:sunday))
        Rigor.dump_type(t.at_end_of_week(:sunday))
        t.beginning_of_day(1, 2)
      RUBY
      result = run_plugin(source: source)
      arity = result.diagnostics.select { |d| d.qualified_rule == "call.wrong-arity" }

      expect(arity.map(&:message)).to eq(
        ["wrong number of arguments to `beginning_of_day' on Time (given 2, expected 0)"]
      )
      expect(dumps(result)).to eq(["dump_type: Time"] * 3)
    end

    # `formatted_offset(colon = true, …)` branches on plain truthiness (`colon ? WITH_COLON :
    # WITHOUT_COLON`), which rbs spells `boolish`. Declared `bool` it drew
    # `call.argument-type-mismatch` on `formatted_offset(1)` — code that runs fine. The last line is
    # the must-still-fire half: a genuinely wrong argument on the new surface still reports, so this
    # is `boolish` being exact and not argument checking going quiet.
    it "takes any truthy colon for formatted_offset, and still catches a genuinely wrong argument" do
      source = <<~RUBY
        t = Time.current
        Rigor.dump_type(t.formatted_offset(1))
        Rigor.dump_type(t.formatted_offset(false))
        t.days_ago("3")
      RUBY
      result = run_plugin(source: source)
      mismatches = result.diagnostics.select { |d| d.qualified_rule == "call.argument-type-mismatch" }

      expect(mismatches.map(&:message)).to eq(
        [%(argument type mismatch at parameter `days' of `days_ago' on Time: expected Numeric, got "3")]
      )
      expect(dumps(result)).to eq(["dump_type: String"] * 2)
    end

    it "declares the Time singletons core_ext/time/zones and time/calculations add" do
      source = <<~RUBY
        Time.zone_default
        Time.use_zone("UTC") { 1 }
        Time.find_zone!("UTC")
        Time.find_zone("UTC")
        Rigor.dump_type(Time.days_in_month(2, 2024))
        Rigor.dump_type(Time.days_in_year)
        Rigor.dump_type(Time.rfc3339("1999-12-31T14:00:00-10:00"))
      RUBY
      result = run_plugin(source: source)

      expect(undefined_methods(result)).to be_empty
      expect(dumps(result)).to eq(["dump_type: Integer", "dump_type: Integer", "dump_type: Time"])
    end
  end

  # Issue #670 — the `Date` / `DateTime` half of #658. Both are CLOSED core classes carrying the same
  # undeclared `DateAndTime::Calculations` / `Zones` surface, so the same omission-is-a-false-positive
  # rule applies. What makes it more than "#658 again for two more classes" is that `DateTime < Date`:
  # every row declared on `Date` is INHERITED by `DateTime`, and for most of the shared module the
  # inherited return is wrong, so declaring the surface on `Date` alone would have CONVERTED the
  # undefined-method false positives into wrong-return ones rather than fixing them.
  describe "the Rails Date and DateTime instance surface (#670)" do
    def dumps(result)
      result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    end

    def undefined_methods(result)
      result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
    end

    # The four calls the issue opened on, verbatim. Each is `error: undefined method … for Date` /
    # `… for DateTime` on master with this plugin loaded.
    let(:issue_source) do
      <<~RUBY
        Date.current.past?
        Date.current.beginning_of_quarter
        DateTime.now.past?
        DateTime.now.beginning_of_quarter
        Date.current.in_time_zone
      RUBY
    end

    it "reports nothing for the Rails Date / DateTime calls the issue opened on" do
      expect(undefined_methods(run_plugin(source: issue_source))).to be_empty
    end

    # The must-still-succeed half, and it is the mandatory one: the failure mode of this change is a
    # class that silently stops reporting anything (#437 — a duplicate declaration collapses the whole
    # class to `Dynamic[top]`), and that failure looks exactly like a green must-not-fire assertion.
    it "still witnesses a genuinely undefined method on a Date and on a DateTime receiver" do
      result = run_plugin(
        source: "#{issue_source}Date.current.definitely_not_a_method\nDateTime.now.also_not_a_method\n"
      )

      expect(undefined_methods(result).size).to eq(2)
      expect(undefined_methods(result).join).to include("definitely_not_a_method", "also_not_a_method")
    end

    # The other half of "no silent collapse": a declared return has to RESOLVE, not merely fail to draw
    # a diagnostic. A collapsed class answers `Dynamic[top]` for every one of these.
    it "resolves the new Date surface to real types rather than leaving it Dynamic" do
      source = <<~RUBY
        d = Date.current
        Rigor.dump_type(d.beginning_of_quarter)
        Rigor.dump_type(d.days_ago(3))
        Rigor.dump_type(d.quarter)
        Rigor.dump_type(d.all_month)
        Rigor.dump_type(d.to_fs(:db))
        Rigor.dump_type(d.middle_of_day)
        Rigor.dump_type(d.months_since(2).end_of_year.to_fs(:db))
      RUBY

      expect(dumps(run_plugin(source: source))).to eq(
        [
          "dump_type: Date", "dump_type: Date", "dump_type: Integer", "dump_type: Range[Date]",
          "dump_type: String", "dump_type: Time", "dump_type: String"
        ]
      )
    end

    # THE regression this issue exists for. `DateTime.now.beginning_of_month` typed as `Date` on master
    # — inherited from the `Date` block — while returning a `DateTime` at runtime, so `.hour` on the
    # result was a latent false positive independent of the undeclared surface. Every row whose return
    # differs between the two classes needed an explicit override, and this is the assertion that the
    # overrides are actually in force rather than the `Date` rows leaking through.
    it "types the DateTime calculations family as DateTime, not as the inherited Date" do
      source = <<~RUBY
        t = DateTime.now
        Rigor.dump_type(t.beginning_of_month)
        Rigor.dump_type(t.beginning_of_month.hour)
        Rigor.dump_type(t.beginning_of_quarter)
        Rigor.dump_type(t.days_ago(3))
        Rigor.dump_type(t.last_year)
        Rigor.dump_type(t.all_month)
        Rigor.dump_type(t.middle_of_day)
        Rigor.dump_type(t.seconds_since_midnight)
      RUBY
      result = run_plugin(source: source)

      expect(undefined_methods(result)).to be_empty
      expect(dumps(result)).to eq(
        [
          "dump_type: DateTime", "dump_type: Integer", "dump_type: DateTime", "dump_type: DateTime",
          "dump_type: DateTime", "dump_type: Range[DateTime]", "dump_type: DateTime",
          "dump_type: Integer"
        ]
      )
    end

    # Not every inherited row is wrong, and getting that half right matters as much: `DateTime.yesterday`
    # and `.tomorrow` are a hardcoded `::Date.current.yesterday` in the source and really do answer a
    # `Date`, so overriding them would have been the false positive. `DateTime.current` is the singleton
    # that IS wrong inherited. Verified by calling all three against activesupport-8.1.3.1.
    it "overrides DateTime.current but leaves DateTime.yesterday / .tomorrow answering Date" do
      source = <<~RUBY
        Rigor.dump_type(DateTime.current)
        Rigor.dump_type(DateTime.yesterday)
        Rigor.dump_type(DateTime.tomorrow)
        Rigor.dump_type(Date.current)
      RUBY

      expect(dumps(run_plugin(source: source))).to eq(
        ["dump_type: DateTime", "dump_type: Date", "dump_type: Date", "dump_type: Date"]
      )
    end

    # `at_beginning_of_week` / `at_end_of_week` are `alias`es of the `start_day`-taking methods on both
    # classes — the same FP #658 found on the `Time` twins, in rows this change is adding rather than
    # in rows that were already there. The last line is the must-still-fire half: a genuinely
    # over-applied zero-arity method still reports, so this is not the receiver going lenient.
    it "takes the optional start_day on the at_-prefixed week aliases, and still catches a real overrun" do
      source = <<~RUBY
        d = Date.current
        Rigor.dump_type(d.at_beginning_of_week(:sunday))
        Rigor.dump_type(d.at_end_of_week(:sunday))
        Rigor.dump_type(DateTime.now.at_beginning_of_week(:sunday))
        d.beginning_of_quarter(1, 2)
      RUBY
      result = run_plugin(source: source)
      arity = result.diagnostics.select { |d| d.qualified_rule == "call.wrong-arity" }

      expect(arity.map(&:message)).to eq(
        ["wrong number of arguments to `beginning_of_quarter' on Date (given 2, expected 0)"]
      )
      expect(dumps(result)).to eq(["dump_type: Date", "dump_type: Date", "dump_type: DateTime"])
    end

    # The week-start configuration singletons `core_ext/date/calculations.rb` adds behind
    # `Date.beginning_of_week`. `Date` is closed, so these omissions fired on an ordinary
    # `config/initializers` line.
    it "declares the Date week-start configuration singletons" do
      source = <<~RUBY
        Date.beginning_of_week = :sunday
        Date.beginning_of_week_default
        Rigor.dump_type(Date.find_beginning_of_week!(:monday))
      RUBY
      result = run_plugin(source: source)

      expect(undefined_methods(result)).to be_empty
      expect(dumps(result)).to eq(["dump_type: Symbol"])
    end
  end

  # Issue #762. This bundle declared nine `Date` singletons; ActiveSupport 8.1.3.1 defines four of
  # those names on `Date`'s `class << self` and five nowhere at all. Re-verified against the vendored
  # gem two ways before the fix — the `class << self` block in `core_ext/date/calculations.rb` reads
  # `beginning_of_week`, `beginning_of_week=`, `find_beginning_of_week!`, `yesterday`, `tomorrow`,
  # `current` and nothing else, and at runtime after `require "active_support/all"`,
  # `Date.respond_to?` answers false for all five phantoms while every one of them resolves as an
  # INSTANCE method owned by `DateAndTime::Calculations`.
  #
  # This direction of error is the rarer one. The usual closed-class bug is an OMISSION, which costs
  # a false positive; these five were the opposite — extra declarations that SUPPRESS a true
  # positive, so `rigor check` accepted `Date.end_of_month` and then typed the `NoMethodError` it
  # raises as a `Date` for everything downstream. `DateTime` inherited all five through its singleton.
  describe "the Date singletons ActiveSupport does not define (#762)" do
    def dumps(result)
      result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    end

    def undefined_methods(result)
      result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
    end

    # The must-STILL-fire half, and here it is the primary assertion rather than the pairing: each of
    # these five is a genuine `NoMethodError`, so reporting them is the fix, not a regression.
    it "reports every one of the five phantom singletons on Date and on DateTime" do
      source = <<~RUBY
        Date.end_of_week
        Date.beginning_of_month
        Date.end_of_month
        Date.beginning_of_year
        Date.end_of_year
        DateTime.end_of_month
      RUBY
      result = run_plugin(source: source)

      expect(undefined_methods(result).size).to eq(6)
      expect(undefined_methods(result).join).to include(
        "end_of_week", "beginning_of_month", "end_of_month", "beginning_of_year", "end_of_year"
      )
    end

    # The pairing, and the one that makes the removal a correction rather than a blunt deletion: the
    # five names are real ActiveSupport API on an INSTANCE receiver, and every one still resolves to a
    # real `Date`. Deleting them from the wrong nesting level would have taken these with them.
    it "keeps all five resolving on an instance receiver, where they actually live" do
      source = <<~RUBY
        d = Date.current
        Rigor.dump_type(d.end_of_week)
        Rigor.dump_type(d.beginning_of_month)
        Rigor.dump_type(d.end_of_month)
        Rigor.dump_type(d.beginning_of_year)
        Rigor.dump_type(d.end_of_year)
      RUBY
      result = run_plugin(source: source)

      expect(undefined_methods(result)).to be_empty
      expect(dumps(result)).to eq(Array.new(5, "dump_type: Date"))
    end

    # The sixth. It exists, so it must not be reported — but a silent collapse to `Dynamic` also
    # reports nothing, so the load-bearing assertion is that it RESOLVES, and to `Symbol`.
    # `find_beginning_of_week!` returns the identical value and already said `Symbol`.
    it "types Date.beginning_of_week as the Symbol week start, not as a Date" do
      source = <<~RUBY
        Rigor.dump_type(Date.beginning_of_week)
        Rigor.dump_type(DateTime.beginning_of_week)
        Rigor.dump_type(Date.find_beginning_of_week!(:monday))
      RUBY
      result = run_plugin(source: source)

      expect(undefined_methods(result)).to be_empty
      expect(dumps(result)).to eq(Array.new(3, "dump_type: Symbol"))
    end

    # The three real date-constructing singletons are untouched, asserted by resolution: if the edit
    # had over-reached and emptied the block, this would read `Dynamic[top]` while the phantom
    # assertion above stayed green.
    it "leaves Date.current / .yesterday / .tomorrow answering Date" do
      source = <<~RUBY
        Rigor.dump_type(Date.current)
        Rigor.dump_type(Date.yesterday)
        Rigor.dump_type(Date.tomorrow)
        Rigor.dump_type(Date.current.beginning_of_quarter)
      RUBY
      result = run_plugin(source: source)

      expect(undefined_methods(result)).to be_empty
      expect(dumps(result)).to eq(Array.new(4, "dump_type: Date"))
    end
  end

  # Issue #534 item 3. The multipliers were `() -> untyped` in the RBS bundle, so `1.day` was
  # `Dynamic[top]` on ~265 mastodon sites. They now return the RBS-less `ActiveSupport::Duration`
  # nominal, and the arithmetic rule keeps the operators around it honest.
  describe "Duration multipliers (#534)" do
    def dumps(result)
      result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    end

    def rules(result)
      result.diagnostics.map(&:qualified_rule)
    end

    it "types every multiplier as ActiveSupport::Duration, on Integer and Float receivers" do
      names = Rigor::Plugin::ActivesupportCoreExt::DURATION_MULTIPLIERS
      source = names.map { |n| "Rigor.dump_type(1.#{n})" }.join("\n")
      # `fortnight(s)` is Integer-only in the bundle, so the Float sweep skips it.
      source += "\n#{(names - %i[fortnight fortnights]).map { |n| "Rigor.dump_type(2.5.#{n})" }.join("\n")}\n"
      result = run_plugin(source: source)

      expect(dumps(result).size).to eq((names.size * 2) - 2)
      expect(dumps(result)).to all(eq("dump_type: ActiveSupport::Duration"))
    end

    it "types a multiplier on a non-literal Integer receiver" do
      result = run_plugin(source: "n = 3\nRigor.dump_type(n.days)\n")
      expect(dumps(result)).to eq(["dump_type: ActiveSupport::Duration"])
    end

    # Issue #632. `ActiveSupport::Duration` IS now declared (`sig/active_support/core_ext.rbs`) — reversing
    # the #534-era "leaves the Duration surface lenient" test above, which asserted every one of these
    # stayed `Dynamic[top]`. What keeps the class safe to name is `open_receivers: ["ActiveSupport::Duration"]`
    # on the manifest (ADR-26): `call.undefined-method` never fires against a Duration receiver, so the
    # readers below can resolve precisely while the rest of the class (arithmetic, `==`, and anything
    # `method_missing` forwards to the wrapped numeric) stays undeclared without becoming a false positive.
    #
    # `ago`/`until`/`before`/`since`/`from_now`/`after` joined these readers in #659; their own describe
    # block is below. They were held back until #658 and #670 had declared the Rails `Time` / `Date` /
    # `DateTime` surface, because the diagnostic they caused landed on the `Time` they RETURN, where
    # open_receivers has no reach.
    it "resolves the declared reader surface to real types" do
      source = <<~RUBY
        Rigor.dump_type(1.day.to_i)
        Rigor.dump_type(3.hours.in_minutes)
        Rigor.dump_type(1.week.iso8601)
        Rigor.dump_type(1.day.parts)
        Rigor.dump_type(1.5.seconds.parts)
      RUBY
      result = run_plugin(source: source)
      expect(rules(result)).not_to include("call.undefined-method")
      expect(dumps(result)).to eq(
        [
          "dump_type: Integer",
          "dump_type: Float",
          "dump_type: String",
          "dump_type: Hash[Symbol, Float | Integer]",
          "dump_type: Hash[Symbol, Float | Integer]"
        ]
      )
    end

    it "still declines a method_missing member to Dynamic without firing undefined-method" do
      # `round` is real Duration API that `method_missing` forwards to the wrapped numeric, so it stays
      # undeclared on purpose — `sig/active_support/core_ext.rbs`'s own top-of-block comment. It declines
      # to `Dynamic` rather than firing `call.undefined-method`, and open_receivers is what keeps it
      # silent. `1.day.ago` used to be asserted here for the same shape; #659 declares it, so it moved to
      # the block below and this example keeps only the member that is still genuinely undeclared.
      result = run_plugin(source: "Rigor.dump_type(1.day.round)\n")

      expect(rules(result)).not_to include("call.undefined-method")
      expect(dumps(result)).to eq(["dump_type: Dynamic[top]"])
    end

    # Issue #659, the half of #632's Duration surface that could not land with it. `since` and `ago` are
    # the only two real methods (`from_now` / `after` alias the first, `until` / `before` the second —
    # checked against activesupport 8.1.3.1, since a mis-transcribed alias arity is the bug #658 found on
    # `Time#at_beginning_of_week`), and every FP-viable return routes into `Time`. That was the blocker:
    # `Time` is a CLOSED core class, and until #658 declared its Rails instance surface, typing `ago` as
    # `Time` moved the false positive from the Duration receiver onto the returned `Time` — where
    # `open_receivers: ["ActiveSupport::Duration"]` has no reach.
    #
    # `Time` is the honest class rather than a compromise: under a zone these answer an
    # `ActiveSupport::TimeWithZone`, and Rails overrides `TimeWithZone#is_a?` to answer true for `::Time`.
    # A `Time | ActiveSupport::TimeWithZone` union was measured and rejected — it fires nothing but types
    # the whole downstream chain `Dynamic[top]`, which buys no more than leaving the methods undeclared.
    describe "the Duration ago family (#659)" do
      def undefined_methods(result)
        result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
      end

      it "types all six zero-arg spellings as Time" do
        source = <<~RUBY
          Rigor.dump_type(30.minutes.ago)
          Rigor.dump_type(30.minutes.until)
          Rigor.dump_type(30.minutes.before)
          Rigor.dump_type(30.minutes.since)
          Rigor.dump_type(30.minutes.from_now)
          Rigor.dump_type(30.minutes.after)
        RUBY
        result = run_plugin(source: source)

        expect(undefined_methods(result)).to be_empty
        expect(dumps(result)).to eq(Array.new(6, "dump_type: Time"))
      end

      # The point of declaring them at all: the chain has to keep resolving past the `Time`. Each of
      # these reads a real type only because #658 and #670 declared the surface they land on — a
      # collapsed `Time` would answer `Dynamic[top]` here while every must-not-fire assertion stayed
      # green.
      it "resolves the Rails Time chain hanging off the returned value" do
        source = <<~RUBY
          Rigor.dump_type(30.minutes.ago.iso8601)
          Rigor.dump_type(1.day.ago.to_fs(:db))
          Rigor.dump_type(2.hours.from_now.beginning_of_day)
          Rigor.dump_type(1.week.ago.to_date)
          Rigor.dump_type(3.days.ago.past?)
          Rigor.dump_type(1.day.ago.at_beginning_of_hour)
        RUBY
        result = run_plugin(source: source)

        expect(undefined_methods(result)).to be_empty
        expect(dumps(result)).to eq(
          [
            "dump_type: String", "dump_type: String", "dump_type: Time",
            "dump_type: Date", "dump_type: bool", "dump_type: Time"
          ]
        )
      end

      # The with-an-argument form declines on purpose. The runtime return depends on the argument's
      # class AND on whether the duration carries a date-scale part — `(1.month).ago(Date.today)` is a
      # `Date` where `(30.minutes).ago(Date.today)` is a `TimeWithZone` — so no overload expresses it
      # without guessing, and a guess is a false positive on correct code. It must decline to `Dynamic`
      # WITHOUT firing, which is the arity half of the assertion too: declaring only `() -> Time` would
      # have made every one-argument call a `call.wrong-arity` on correct Rails.
      it "declines the with-an-argument form to Dynamic rather than guessing, and never on arity" do
        source = <<~RUBY
          Rigor.dump_type(1.month.ago(Date.today))
          Rigor.dump_type(30.minutes.ago(Time.now))
          Rigor.dump_type(1.day.since(Time.now))
          Rigor.dump_type(2.weeks.from_now(Date.current))
        RUBY
        result = run_plugin(source: source)

        expect(rules(result)).not_to include("call.wrong-arity", "call.undefined-method")
        expect(dumps(result)).to eq(Array.new(4, "dump_type: Dynamic[top]"))
      end

      # The must-still-fire pairing. Silence is not evidence here: an `ActiveSupport::Duration` receiver
      # is an open receiver, so the genuine diagnostic this change must not swallow is the one on the
      # returned `Time`, which is closed.
      it "still witnesses a genuinely undefined method on the returned Time" do
        result = run_plugin(source: "1.day.ago.definitely_not_a_time_method\n")

        expect(undefined_methods(result).size).to eq(1)
        expect(undefined_methods(result).first).to include("definitely_not_a_time_method", "Time")
      end
    end

    it "does NOT retype `day` / `month` / `year` / `hour` on Time and Date receivers" do
      # The FP boundary. These are real Integer-returning methods on Time / Date, so a name-only rule
      # would silently turn `created_at.day` into a Duration.
      source = <<~RUBY
        t = Time.now
        Rigor.dump_type(t.day)
        Rigor.dump_type(t.month)
        Rigor.dump_type(t.year)
        Rigor.dump_type(t.hour)
        d = Date.today
        Rigor.dump_type(d.day)
        Rigor.dump_type(d.year)
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result).size).to eq(6)
      expect(dumps(result)).to all(eq("dump_type: Integer"))
    end

    it "does NOT retype a project's own `days` method" do
      source = <<~RUBY
        class Widget
          def days
            7
          end
        end

        Rigor.dump_type(Widget.new.days)
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(["dump_type: 7"])
    end

    describe "the arithmetic correction" do
      # Typing the multiplier alone regressed five shapes, because the overload selector commits when the
      # argument is a named class it has no RBS for. Each assertion below is one of the measured
      # regressions, and each one fails (with a `call.undefined-method` on the line after it) if the
      # arithmetic rule is removed while the multiplier rule stays.
      it "keeps `Time` ± Duration a Time" do
        source = <<~RUBY
          t = Time.now
          Rigor.dump_type(t + 3.days)
          Rigor.dump_type(t - 30.minutes)
          (Time.now - 30.minutes).beginning_of_day
        RUBY
        result = run_plugin(source: source)
        expect(dumps(result)).to eq(["dump_type: Time", "dump_type: Time"])
        expect(rules(result)).not_to include("call.undefined-method")
      end

      it "keeps numeric ± / * Duration a Duration" do
        source = <<~RUBY
          Rigor.dump_type(2 * 1.day)
          Rigor.dump_type(3 + 1.day)
          Rigor.dump_type(1.day + 1.hour)
          Rigor.dump_type(1.day * 2)
          (2 * 1.day).ago
          (3 + 1.day).from_now
        RUBY
        result = run_plugin(source: source)
        expect(dumps(result)).to all(eq("dump_type: ActiveSupport::Duration"))
        expect(dumps(result).size).to eq(4)
        expect(rules(result)).not_to include("call.undefined-method")
      end

      it "widens `Date` ± Duration to the two kinds the duration's parts can make" do
        # `Duration#since` returns a Date for a date-part duration and a Time for a sub-day one, so the
        # union is the runtime contract. Without the rule this commits to `Rational` and the next line is
        # `undefined method 'year' for Rational`.
        source = <<~RUBY
          Rigor.dump_type(Date.today + 1.day)
          Rigor.dump_type(Date.today - 1.week)
          (Date.today - 1.week).year
          (Date.today + 1.hour).hour
        RUBY
        result = run_plugin(source: source)
        expect(dumps(result).size).to eq(2)
        expect(dumps(result)).to all(eq("dump_type: Date | Time"))
        expect(rules(result)).not_to include("call.undefined-method")
      end

      it "leaves arithmetic with no Duration operand exactly as it was" do
        source = <<~RUBY
          Rigor.dump_type(1 + 1)
          Rigor.dump_type(2 * 3)
          Rigor.dump_type(1 - 1)
          Rigor.dump_type("a" + "b")
          Rigor.dump_type([1] + [2])
          Rigor.dump_type(Time.now - Time.now)
          Rigor.dump_type(Date.today - Date.today)
          Rigor.dump_type(Time.now - 1)
          Rigor.dump_type(Date.today + 1)
        RUBY
        result = run_plugin(source: source)
        expect(dumps(result)).to eq(
          [
            "dump_type: 2", "dump_type: 6", "dump_type: 0", 'dump_type: "ab"', "dump_type: [1, 2]",
            "dump_type: Float", "dump_type: Rational", "dump_type: Time", "dump_type: Date"
          ]
        )
      end

      it "declines the operator pairs whose answer depends on the operand" do
        # `1.day / 2` is a Duration but `1.day / 1.hour` is a plain 24; `Duration * Duration` is not a
        # quantity Rails promises. Both stay lenient rather than guessing.
        result = run_plugin(source: "Rigor.dump_type(1.day / 2)\nRigor.dump_type(1.day * 1.day)\n")
        expect(dumps(result)).to all(eq("dump_type: Dynamic[top]"))
        expect(dumps(result).size).to eq(2)
      end

      it "declines a Duration on the left of a Time / DateTime / Date — every one of those raises (#588)" do
        # `Duration#+` adds a non-Duration operand to its seconds part, so `30.minutes + Time.now` is
        # `Integer + Time` (TypeError); `-` sends `-@` to the Time (NoMethodError); `*` is a TypeError from
        # `Duration#calculate`. Measured on ActiveSupport 8.1: 7/7 shapes raise. A crashing expression gets
        # no type, not a Duration, so the RBS-less receiver stays lenient.
        source = <<~RUBY
          Rigor.dump_type(30.minutes + Time.now)
          Rigor.dump_type(30.minutes - Time.now)
          Rigor.dump_type(30.minutes * Time.now)
          Rigor.dump_type(1.day + Date.today)
          Rigor.dump_type(1.day - Date.today)
          Rigor.dump_type(1.day * Date.today)
          Rigor.dump_type(1.day + DateTime.now)
        RUBY
        result = run_plugin(source: source)
        expect(dumps(result).size).to eq(7)
        expect(dumps(result)).to all(eq("dump_type: Dynamic[top]"))
      end

      it "still types Duration ± numeric and numeric ± Duration in both orders, Integer and Float" do
        # The must-still-type sibling of the decline above: the argument-side check removes only the
        # date/time kinds, never a numeric — each of these is a Duration at runtime (measured alongside).
        source = <<~RUBY
          Rigor.dump_type(1.day + 3)
          Rigor.dump_type(1.day - 3)
          Rigor.dump_type(3 - 1.day)
          Rigor.dump_type(1.day + 2.5)
          Rigor.dump_type(2.5 + 1.day)
          Rigor.dump_type(1.day * 2)
          Rigor.dump_type(2 * 1.day)
        RUBY
        result = run_plugin(source: source)
        expect(dumps(result).size).to eq(7)
        expect(dumps(result)).to all(eq("dump_type: ActiveSupport::Duration"))
      end

      # #588 — the rule is consulted on every `+` / `-` / `*` in the project, and its comment promises the
      # argument gate runs FIRST so a call with no Duration operand costs one type lookup, not two. That
      # is invisible to a dump (the answer is nil either way), so it is pinned directly against the rule
      # with a recording scope. The pair below is the discrimination: without the early exit both
      # examples type the receiver.
      describe "the argument gate runs before the receiver lookup (#588)" do
        let(:services) do
          Rigor::Plugin::Services.new(
            reflection: Rigor::Reflection, type: Rigor::Type::Combinator, configuration: Rigor::Configuration.new
          )
        end
        let(:plugin) { plugin_class.new(services: services) }
        let(:asked) { [] }

        # A scope that answers every `type_of` from `answers` (keyed by the queried node) and records the
        # order it was asked in.
        def recording_scope(answers)
          scope = instance_double(Rigor::Scope, environment: nil)
          allow(scope).to receive(:type_of) do |queried|
            asked << queried
            answers.fetch(queried)
          end
          scope
        end

        def binary_call(source)
          Prism.parse(source).value.statements.body.first
        end

        it "never types the receiver when the argument is no Duration operand" do
          node = binary_call('lhs + "s"')
          argument = node.arguments.arguments.first
          scope = recording_scope(argument => Rigor::Type::Combinator.constant_of("s"))

          result = plugin.dynamic_return_type(call_node: node, scope: scope, receiver_type: Rigor::Type::Combinator.top)

          expect(result).to be_nil
          expect(asked).to eq([argument])
        end

        it "still types the receiver once the argument is a Duration operand" do
          node = binary_call("lhs + 1.day")
          argument = node.arguments.arguments.first
          scope = recording_scope(
            argument => Rigor::Type::Combinator.nominal_of("ActiveSupport::Duration"),
            node.receiver => Rigor::Type::Combinator.constant_of(3)
          )

          result = plugin.dynamic_return_type(call_node: node, scope: scope, receiver_type: Rigor::Type::Combinator.top)

          expect(result).to eq(Rigor::Type::Combinator.nominal_of("ActiveSupport::Duration"))
          expect(asked).to eq([argument, node.receiver])
        end
      end
    end

    it "CONTROL: the harness fires undefined-method in this fixture shape" do
      # The must-fire sibling for every `not_to include(\"call.undefined-method\")` above.
      result = run_plugin(source: %(1.no_such_method_on_integer\n))
      expect(rules(result)).to include("call.undefined-method")
    end
  end
end
