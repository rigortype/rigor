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
    # `ago`/`until`/`before`/`since`/`from_now`/`after` are deliberately NOT among these readers — see the
    # `ActiveSupport::Duration` class comment in `sig/active_support/core_ext.rbs` (issue #659, blocked on
    # #658): they default to `Time.current`, and typing them needs the Rails `Time` instance surface, which
    # is a CLOSED core class this bundle does not declare, first. A review round caught exactly this: typing
    # `ago` `() -> Time` fired 9 false positives on real Rails `Time` extension calls
    # (`.ago.to_fs(:db)`, `.ago.in_time_zone`, …) that read `Dynamic` and silent on master. The with-argument
    # / undeclared-member test below covers `ago` itself, proving it is back to declining safely.
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

    it "still witnesses no undefined-method for ago/since (undeclared, #659/#658) or a method_missing member" do
      # `ago` / `since` are real Duration API this declaration does NOT list (issue #659, blocked on #658 —
      # the Rails `Time` instance surface is a closed core class this bundle doesn't declare). `round` is
      # real Duration API `method_missing`-forwards to the wrapped numeric — a DIFFERENT reason to stay
      # undeclared, from `sig/active_support/core_ext.rbs`'s own top-of-block comment. Both shapes decline
      # to `Dynamic` rather than fire `call.undefined-method`, and open_receivers is what keeps them silent.
      source = <<~RUBY
        Rigor.dump_type(1.day.ago)
        Rigor.dump_type(1.day.since(Time.now))
        Rigor.dump_type(1.day.round)
      RUBY
      result = run_plugin(source: source)
      expect(rules(result)).not_to include("call.undefined-method")
      expect(dumps(result)).to all(eq("dump_type: Dynamic[top]"))
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
