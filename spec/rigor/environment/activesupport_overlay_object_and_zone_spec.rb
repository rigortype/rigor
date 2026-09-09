# frozen_string_literal: true

# Issue #673 — two of the three gaps the #658 review left behind, on the AUTO-APPLIED half of the
# ADR-72 bundle (`data/gem_overlay/activesupport/core_ext.rbs`). The plugin twin carries the same rows
# and is exercised by `spec/integration/plugins/activesupport_core_ext_plugin_spec.rb`; the parity guard
# keeps the two declaration sets in step, but not their TYPES, which is what this file pins.
#
# Gap 1 — `Time.current` was declared `() -> Time` while it answers an `ActiveSupport::TimeWithZone`
# under a zone, and TWZ was not modelled at all, so `Time.current.time_zone` (and `time`, `period`,
# `comparable_time`) was `call.undefined-method` on correct Rails code. TWZ is now a `::Time` SUBCLASS,
# which is what lets the four readers resolve WITHOUT the rest of the chain widening: a union was
# measured during #632 and types every downstream call `Dynamic[top]`.
#
# Gap 2 — `to_param` / `to_query` were declared only on `Hash` and `duplicable?` / `instance_values` only
# on `NilClass`, though ActiveSupport defines all five (plus `instance_variable_names`) on `Object`. Every
# RBS-known receiver therefore reported `call.undefined-method` on them.
#
# Every example pins a resolved TYPE next to the absent diagnostic. An absence-only assertion cannot tell
# a fixed row from a collapsed class: a duplicate declaration raises `RBS::DuplicatedMethodDefinitionError`
# and takes the whole class down to `Dynamic[top]`, which reports nothing at all (#672, #437).
require "spec_helper"
require "tmpdir"

RSpec.describe "ADR-72 ActiveSupport overlay — Object core-ext and TimeWithZone (#673)" do
  def gemfile_lock
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (7.1.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        activesupport

      BUNDLED WITH
         2.5.6
    LOCK
  end

  def run_source(source)
    Dir.mktmpdir("rigor-as-overlay-673-") do |dir|
      File.write(File.join(dir, "Gemfile.lock"), gemfile_lock)
      File.write(File.join(dir, "code.rb"), source)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => [File.join(dir, "code.rb")],
          "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
        )
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map { |d| d.message.sub("dump_type: ", "") }
  end

  def undefined_methods(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:method_name)
  end

  describe "gap 1 — ActiveSupport::TimeWithZone" do
    let(:result) do
      run_source(<<~RUBY)
        t = Time.current
        Rigor.dump_type(t)
        Rigor.dump_type(t.time_zone)
        Rigor.dump_type(t.time)
        Rigor.dump_type(t.period)
        Rigor.dump_type(t.comparable_time)
        Rigor.dump_type(t.to_i)
        Rigor.dump_type(t.beginning_of_day)
        Rigor.dump_type(t.to_fs(:db))
      RUBY
    end

    it "types Time.current as the zone-aware class and resolves its four TWZ-only readers" do
      expect(undefined_methods(result)).to be_empty
      expect(dumps(result).first).to eq("ActiveSupport::TimeWithZone")
    end

    # The half a "no diagnostics" assertion cannot see. `time` and `comparable_time` are declared
    # `::Time`; `to_i` / `beginning_of_day` / `to_fs` are `Time`'s own rows reached by INHERITANCE, and
    # a union at the producer would have made all three `Dynamic[top]` instead.
    it "keeps the chain through Time.current resolving rather than widening" do
      expect(dumps(result)).to eq(
        ["ActiveSupport::TimeWithZone", "Dynamic[top]", "Time", "Dynamic[top]", "Time", "Integer", "Time", "String"]
      )
    end

    # The must-still-fire pin. A plain `Time` genuinely lacks all four readers, so declaring them on
    # `Time` — the cheap fix this issue rejected — would have made a real `NoMethodError` silent.
    it "still reports the same four readers on a plain Time receiver" do
      result = run_source(<<~RUBY)
        Time.now.time_zone
        Time.now.period
        Time.current.no_such_method_at_all
      RUBY
      expect(undefined_methods(result)).to eq(%w[time_zone period no_such_method_at_all])
    end
  end

  describe "gap 2 — the Object-level core-ext methods" do
    it "resolves all five on an arbitrary closed receiver" do
      result = run_source(<<~RUBY)
        Rigor.dump_type("abc".to_param)
        Rigor.dump_type("abc".to_query("k"))
        Rigor.dump_type("abc".duplicable?)
        Rigor.dump_type("abc".instance_values)
        Rigor.dump_type("abc".instance_variable_names)
        Rigor.dump_type(1.to_param)
        Rigor.dump_type([1, 2].to_query("k"))
      RUBY

      expect(undefined_methods(result)).to be_empty
      expect(dumps(result)).to eq(
        ["String", "String", "bool", "Hash[String, Dynamic[top]]", "Array[String]", "String", "String"]
      )
    end

    # `NilClass` / `TrueClass` / `FalseClass` override `to_param` to return `self`, so the `Object` row's
    # `String` would be a wrong type on all three.
    it "keeps the singleton-value to_param overrides answering self" do
      result = run_source(<<~RUBY)
        Rigor.dump_type(nil.to_param)
        Rigor.dump_type(true.to_param)
        Rigor.dump_type(false.to_param)
      RUBY

      expect(dumps(result)).to eq(%w[nil true false])
    end

    # Non-vacuity for the whole file: `Object` is the ancestor of everything, so a duplicate declaration
    # here would collapse every class at once and every absence assertion above would pass on the wreck.
    it "leaves a genuinely undefined method firing on the receivers it just opened" do
      result = run_source(<<~RUBY)
        Rigor.dump_type("abc".upcase)
        "abc".no_such_method_here
        1.no_such_method_here
      RUBY

      expect(dumps(result)).to eq(["\"ABC\""])
      expect(undefined_methods(result)).to eq(%w[no_such_method_here no_such_method_here])
    end
  end
end
