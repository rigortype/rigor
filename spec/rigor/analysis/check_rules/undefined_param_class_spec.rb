# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #661 — `call.argument-type-mismatch` against a parameter whose declared class carries no
# definition anywhere in the environment.
#
# `sig/app.rbs` naming `ActiveSupport::TimeWithZone` in a project that never brings ActiveSupport's RBS in
# refuted `App.take_twz(Time.now)` with `expected ActiveSupport::TimeWithZone, got Time`, on a call that
# works. Nothing in the environment says what that class is, so nothing could have made ANY argument
# satisfy it — the verdict was the missing signature restated as an error. ADR-26 § WD8 declines the same
# two signature rules on a receiver for the same reason.
#
# The missing name arrives in two shapes, and both are exercised here because the difference is invisible
# from the signature: a name an INSTANCE-method signature references is minted as an empty stub so the
# class builds and reads back as RBS-known, while the same name in a SINGLETON signature is not, because
# the stub pass mirrors rbs's own membership test and never reaches singleton members. The issue's repro
# is the singleton half; the instance half is one edit away.
#
# Every "does not fire" assertion below is paired with a must-still-fire one on the SAME run, because a
# suppression is indistinguishable from a collapsed signature set otherwise — a `sig/` that failed to
# build produces zero diagnostics and passes an absence-only gate.
RSpec.describe "argument-type mismatch on an undefined parameter class" do
  def app_rbs
    <<~RBS
      class App
        def self.take_missing_singleton: (Nowhere::Thing value) -> void
        def take_missing_instance: (Nowhere::Thing value) -> void
        def take_missing_union: (Nowhere::Thing | Nowhere::Other value) -> void
        def take_missing_element: (Array[Nowhere::Thing] value) -> void
        def take_string: (String value) -> void
        def pick_missing: (Nowhere::Thing value) -> void
                        | (Nowhere::Other value) -> void
        def pick_known: (String value) -> void
                      | (Symbol value) -> void
      end
    RBS
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[app.rb], "signature_paths" => %w[sig])
    )
  end

  def arg_mismatches(source)
    Dir.mktmpdir("check-rules-undefined-param-class-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("sig")
        File.write(File.join("sig", "app.rbs"), app_rbs)
        File.write("app.rb", source)
        runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
        guarded_run(runner, %w[app.rb]).diagnostics.select { |d| d.rule == "call.argument-type-mismatch" }
      end
    end
  end

  # The issue's own repro. The must-still-fire half rides on the same run so a collapsed `sig/` cannot
  # pass this example.
  it "declines on a singleton signature's undefined parameter class, and still fires on a known one" do
    mismatches = arg_mismatches(<<~RUBY)
      App.take_missing_singleton(Time.now)
      App.new.take_string(42)
    RUBY

    expect(mismatches.map(&:message)).to contain_exactly(a_string_including("expected String, got 42"))
  end

  # The stubbed half: an instance signature's reference IS minted as an empty class, so `rbs_class_known?`
  # answers true for a class with no ancestry and no members.
  it "declines on an instance signature's undefined parameter class, and still fires on a known one" do
    mismatches = arg_mismatches(<<~RUBY)
      App.new.take_missing_instance(Time.now)
      App.new.take_string(42)
    RUBY

    expect(mismatches.map(&:message)).to contain_exactly(a_string_including("expected String, got 42"))
  end

  # The nil channel decides on the RBS parameter type too, so it declines on the same ground — a class
  # nothing declares cannot be shown to reject nil either.
  it "declines a nil argument against an undefined parameter class, and still fires on a known one" do
    mismatches = arg_mismatches(<<~RUBY)
      App.new.take_missing_instance(nil)
      App.new.take_string(nil)
    RUBY

    expect(mismatches.map(&:message)).to contain_exactly(a_string_including("expected String"))
  end

  it "declines when any union arm names an undefined class" do
    expect(arg_mismatches("App.new.take_missing_union(Time.now)")).to be_empty
  end

  # The gate reads the arms a verdict rests on directly, never type ARGUMENTS: `Array[Nowhere::Thing]` is
  # refuted by an Integer on the `Array` alone, and declining there would lose a report for nothing.
  it "still fires when the undefined class is only a type argument" do
    mismatches = arg_mismatches("App.new.take_missing_element(42)")

    expect(mismatches.map(&:message)).to contain_exactly(a_string_including("expected Array[Nowhere::Thing]"))
  end

  # The multi-overload channels fire only when EVERY overload rejects, so one undefined arm is enough to
  # unseat the premise.
  it "declines a multi-overload call when the overloads' parameter classes are undefined" do
    expect(arg_mismatches("App.new.pick_missing(Time.now)")).to be_empty
  end

  it "still fires a multi-overload call whose parameter classes are all known" do
    mismatches = arg_mismatches("App.new.pick_known(42)")

    expect(mismatches.size).to eq(1)
  end
end
