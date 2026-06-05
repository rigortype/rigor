# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-24 slice 4a — the evaluation-time recorder for unresolved
# implicit-self calls. The central hypothesis these specs validate: by
# recording at the engine's OWN resolution miss point (rather than
# reimplementing resolution in CheckRules, the reverted attempt-1 route),
# the method classes that produced 135 false positives in attempt 1 —
# `module_function` siblings, `Data.define` accessors, inherited /
# included methods — resolve in the engine BEFORE the miss and so never
# reach the recorder. A genuine typo, with no resolution anywhere, is the
# only thing that lands.
RSpec.describe Rigor::Analysis::SelfCallResolutionRecorder do
  # Runs a recording analysis over `files` (`{ "name.rb" => source }`) and
  # returns the set of every recorded unresolved implicit-self call as
  # `[class_name, method_name]` pairs.
  def recorded_calls(files)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      configuration = Rigor::Configuration.new("paths" => [dir])
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: nil, record_self_calls: true
      )
      runner.run
      runner.unresolved_self_calls.values
            .flat_map { |record| record.calls.map { |c| [c.class_name, c.method_name] } }
            .to_set
    end
  end

  it "records a genuine typo'd implicit-self call under the enclosing class" do
    calls = recorded_calls(
      "widget.rb" => <<~RUBY
        class Widget
          def price
            compute_totl
          end

          def compute_total
            100
          end
        end
      RUBY
    )

    expect(calls).to include(["Widget", :compute_totl])
    # The real sibling it typo'd resolves, so it is NOT recorded.
    expect(calls).not_to include(["Widget", :compute_total])
  end

  it "does not record a `module_function` sibling call (attempt-1 FP class #1)" do
    calls = recorded_calls(
      "helper.rb" => <<~RUBY
        module Helper
          module_function

          def outer
            inner
          end

          def inner
            1
          end
        end
      RUBY
    )

    expect(calls.map(&:last)).not_to include(:inner)
  end

  # The engine does not model a `Data.define` / `Struct.new` block method's
  # `self` as the named constant — it types it `Object` — so a synthesized
  # member accessor (`x`) reaches the type-miss choke-point and IS recorded,
  # but under `Object`, never under the `Point` constant. `Object` is never
  # "confidently closed", so the later closed-class gate filters this
  # over-capture naturally; the recorder never attributes it to a project
  # class. (Recorded under `Object`, this is the attempt-1 FP class #2 — and
  # the gate, not the recorder, is what keeps it from re-surfacing.)
  it "attributes a `Data.define` block-form accessor over-capture to Object, never the constant" do
    calls = recorded_calls(
      "point.rb" => <<~RUBY
        Point = Data.define(:x, :y) do
          def magnitude
            x + y
          end
        end
      RUBY
    )

    expect(calls.map(&:first)).not_to include("Point")
  end

  it "does not record a `class X < Data.define(...)` synthesized member read" do
    calls = recorded_calls(
      "money.rb" => <<~RUBY
        class Money < Data.define(:amount, :currency)
          def describe
            "\#{amount} \#{currency}"
          end
        end
      RUBY
    )

    expect(calls.map(&:last)).not_to include(:amount, :currency)
  end

  it "does not record a `class X < Struct.new(...)` synthesized member read" do
    calls = recorded_calls(
      "point.rb" => <<~RUBY
        class Point < Struct.new(:x, :y)
          def magnitude
            x + y
          end
        end
      RUBY
    )

    expect(calls.map(&:last)).not_to include(:x, :y)
  end

  it "does not record an inherited superclass-method call" do
    calls = recorded_calls(
      "base.rb" => <<~RUBY,
        class Base
          def shared
            1
          end
        end
      RUBY
      "child.rb" => <<~RUBY
        class Child < Base
          def go
            shared
          end
        end
      RUBY
    )

    expect(calls.map(&:last)).not_to include(:shared)
  end

  it "does not record an included-module method call (attempt-1 FP class #3)" do
    calls = recorded_calls(
      "greeter.rb" => <<~RUBY
        module Greeting
          def hello
            "hi"
          end
        end

        class Greeter
          include Greeting

          def run
            hello
          end
        end
      RUBY
    )

    expect(calls.map(&:last)).not_to include(:hello)
  end

  it "does not record an explicit-receiver miss (only implicit self is in scope)" do
    calls = recorded_calls(
      "widget.rb" => <<~RUBY
        class Widget
          def go
            self.bogus_method
          end
        end
      RUBY
    )

    expect(calls.map(&:last)).not_to include(:bogus_method)
  end

  it "stays inert (records nothing) on a normal run with the flag off" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "widget.rb"), <<~RUBY)
        class Widget
          def price
            compute_totl
          end
        end
      RUBY
      configuration = Rigor::Configuration.new("paths" => [dir])
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      runner.run

      expect(runner.unresolved_self_calls).to be_empty
      expect(described_class.active?).to be(false)
    end
  end
end
