# frozen_string_literal: true

# Integration spec for `examples/rigor-units/`. Loads the
# example plugin source, drives a real `Analysis::Runner` over
# inline source snippets, and pins the diagnostic shape per
# recognised event. Treat the spec as the executable contract
# for the README's "What the plugin recognises" section.

require "spec_helper"

UNITS_PLUGIN_LIB = File.expand_path("../../../examples/rigor-units/lib", __dir__)
$LOAD_PATH.unshift(UNITS_PLUGIN_LIB) unless $LOAD_PATH.include?(UNITS_PLUGIN_LIB)
require "rigor-units"

RSpec.describe "examples/rigor-units" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Units }

  describe "local-variable binding inference" do
    it "binds a numeric `.kilometers` constructor to Distance" do
      diags = plugin_diagnostics(run_plugin(source: "distance = 100.kilometers\n"))
      expect(diags.size).to eq(1)
      expect(diags.first.message).to eq("local `distance` inferred as Distance")
      expect(diags.first.severity).to eq(:info)
      expect(diags.first.qualified_rule).to eq("plugin.units.inferred-binding")
    end

    it "binds a numeric `.hours` constructor to Time" do
      diags = plugin_diagnostics(run_plugin(source: "t = 2.hours\n"))
      expect(diags.first.message).to eq("local `t` inferred as Time")
    end

    it "propagates dimensions through reads" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        distance = 100.kilometers
        time     = 2.hours
        speed    = distance / time
      RUBY
      expect(diags.map(&:message)).to include(
        "local `distance` inferred as Distance",
        "local `time` inferred as Time",
        "local `speed` inferred as Speed"
      )
    end

    it "infers Speed from chained Distance.per_hour" do
      diags = plugin_diagnostics(run_plugin(source: "limit = 60.kilometers.per_hour\n"))
      expect(diags.first.message).to eq("local `limit` inferred as Speed")
    end

    it "infers Acceleration from chained Distance.per_second_squared" do
      diags = plugin_diagnostics(run_plugin(source: "g = 9.8.meters.per_second_squared\n"))
      expect(diags.first.message).to eq("local `g` inferred as Acceleration")
    end

    it "infers Acceleration from `(Speed - Speed) / Time`" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        v0 = 0.kilometers.per_hour
        v1 = 100.kilometers.per_hour
        dt = 5.seconds
        a  = (v1 - v0) / dt
      RUBY
      expect(diags.find { |d| d.message.include?("`a`") }.message)
        .to eq("local `a` inferred as Acceleration")
    end

    it "infers Speed from Acceleration * Time" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        g = 9.8.meters.per_second_squared
        t = 3.seconds
        v = g * t
      RUBY
      expect(diags.find { |d| d.message.include?("`v`") }.message)
        .to eq("local `v` inferred as Speed")
    end
  end

  describe "`.in_<unit>` query results" do
    it "infers Float from a matching query" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        speed = 60.kilometers.per_hour
        puts speed.in_kilometers_per_hour
      RUBY
      info = diags.find { |d| d.rule == "in-method-result" }
      expect(info.message).to eq(
        "`speed.in_kilometers_per_hour` returns Float (Speed → kilometers per hour)"
      )
      expect(info.severity).to eq(:info)
    end

    it "errors on a query whose unit does not match the receiver dimension" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        speed = 60.kilometers.per_hour
        puts speed.in_meters
      RUBY
      err = diags.find { |d| d.rule == "in-method-mismatch" }
      expect(err.severity).to eq(:error)
      expect(err.message).to start_with("Speed has no `.in_meters` query")
      expect(err.message).to include(".in_meters_per_second")
    end
  end

  describe "dimensional mismatches in operators" do
    it "errors on Distance + Time" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        d = 100.kilometers
        t = 2.hours
        d + t
      RUBY
      err = diags.find { |d| d.rule == "dimension-mismatch" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq(
        "dimensional mismatch: `Distance + Time` is not defined"
      )
    end

    it "errors on Distance / Distance (ratio not modelled)" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        a = 100.kilometers
        b = 50.meters
        a / b
      RUBY
      err = diags.find { |d| d.rule == "dimension-mismatch" }
      expect(err.message).to eq(
        "dimensional mismatch: `Distance / Distance` is not defined"
      )
    end

    it "errors on cross-dimension comparison (Distance <= Time)" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        d = 100.kilometers
        t = 2.hours
        d <= t
      RUBY
      err = diags.find { |d| d.rule == "dimension-mismatch" }
      expect(err.message).to eq(
        "dimensional mismatch: `Distance <= Time` is not defined"
      )
    end

    it "stays silent on same-dimension comparison" do
      diags = plugin_diagnostics(run_plugin(source: <<~RUBY))
        a = 100.kilometers
        b = 50.meters
        a <= b
      RUBY
      expect(diags.select { |d| d.severity == :error }).to be_empty
    end
  end

  describe "the demo file end-to-end" do
    let(:demo_source) { File.read(File.expand_path("../../../examples/rigor-units/demo/demo.rb", __dir__)) }

    it "produces no error diagnostics" do
      diags = plugin_diagnostics(run_plugin(source: demo_source))
      errors = diags.select { |d| d.severity == :error }
      expect(errors).to be_empty, -> { "unexpected errors: #{errors.map(&:message).inspect}" }
    end

    it "binds every dimensional local declared in the demo" do
      diags = plugin_diagnostics(run_plugin(source: demo_source))
      bindings = diags.select { |d| d.rule == "inferred-binding" }.map(&:message)
      expect(bindings).to include(
        "local `distance` inferred as Distance",
        "local `time` inferred as Time",
        "local `total_distance` inferred as Distance",
        "local `speed` inferred as Speed",
        "local `speed_limit` inferred as Speed",
        "local `wind_speed` inferred as Speed",
        "local `car_acceleration` inferred as Acceleration",
        "local `gravity` inferred as Acceleration",
        "local `velocity_after_fall` inferred as Speed"
      )
    end

    it "annotates every `.in_<unit>` call in the demo with a Float result note" do
      diags = plugin_diagnostics(run_plugin(source: demo_source))
      in_method_diags = diags.select { |d| d.rule == "in-method-result" }
      expect(in_method_diags.size).to be >= 4
      expect(in_method_diags).to all(satisfy { |d| d.message.include?("returns Float") })
    end
  end

  describe "#flow_contribution_for return-type contribution (v0.1.2)" do
    # The plugin's MethodTable resolves `Distance / Time -> Speed`,
    # `Distance + Distance -> Distance`, `Speed * Time -> Distance`,
    # etc. The demo's RBS annotates these methods as `untyped`,
    # so without the contribution downstream calls never surface
    # dimensional errors. With the contribution, mis-using the
    # result against the wrong dimension trips
    # `call.undefined-method`. The unit-class declarations live
    # in the demo's `sig/units.rbs`; the helpers re-materialise
    # that file under a tmpdir so the test runs without leaking
    # the demo's working directory.
    let(:units_rbs) { File.read(File.expand_path("../../../examples/rigor-units/demo/sig/units.rbs", __dir__)) }

    def with_units_sigs(source)
      run_plugin(
        source: source,
        files: { "sig/units.rbs" => units_rbs },
        signature_paths: ["sig"]
      )
    end

    it "narrows `Distance / Time` to Speed so non-Speed calls surface" do
      result = with_units_sigs(<<~RUBY)
        distance = 100.kilometers
        time     = 2.hours
        speed    = distance / time
        speed.upcase
      RUBY
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("upcase")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("Speed")
    end

    it "narrows `Distance + Distance` to Distance" do
      result = with_units_sigs(<<~RUBY)
        a = 100.kilometers
        b = 50.kilometers
        total = a + b
        total.upcase
      RUBY
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("upcase")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("Distance")
    end

    it "declines to contribute on dimensional mismatches (existing diagnostic stays)" do
      result = with_units_sigs(<<~RUBY)
        distance = 100.kilometers
        time     = 2.hours
        bogus    = distance + time
        bogus.upcase
      RUBY
      mismatch = plugin_diagnostics(result).find { |d| d.rule == "dimension-mismatch" }
      expect(mismatch).not_to be_nil
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("upcase")
      end
      expect(method_undefined).to be_empty
    end
  end
end
