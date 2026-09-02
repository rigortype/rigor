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

    it "leaves the Duration surface lenient — no undefined-method on the chain" do
      # The whole reason `ActiveSupport::Duration` is not declared in the RBS bundle. Every call below is
      # real Duration API; a declared class would have to enumerate all of it or fire on the remainder.
      source = <<~RUBY
        Rigor.dump_type(1.day.ago)
        Rigor.dump_type(5.minutes.from_now)
        Rigor.dump_type(1.day.to_i)
        Rigor.dump_type(3.hours.in_minutes)
        Rigor.dump_type(1.week.iso8601)
        1.day.since(Time.now)
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
