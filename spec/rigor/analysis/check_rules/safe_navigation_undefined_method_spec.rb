# frozen_string_literal: true

require "spec_helper"

# N3 (docs/notes/20260613-app-network-corpora-survey.md) — a safe-navigation call (`recv&.m`) never dispatches on the
# nil edge of its receiver: at runtime it short-circuits to nil. The `call.undefined-method` existence check must
# therefore apply only to the NON-nil constituents of the receiver. A pure-nil receiver is silent; a `T | nil` receiver
# is checked against `T` alone.
RSpec.describe "safe-navigation undefined-method suppression" do
  def diagnostics_for(source)
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
    guarded_run_source(runner, source: source, path: "mem.rb").diagnostics
  end

  def undefined_method_messages(source)
    diagnostics_for(source).select { |d| d.rule == "call.undefined-method" }.map(&:message)
  end

  it "stays silent for a `&.` call on a receiver that types as exactly nil" do
    source = <<~RUBY
      class T
        def initialize
          @t = nil
        end

        def alive
          @t&.alive?
        end
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "still fires for a plain (non-safe-nav) call on a nil receiver" do
    source = <<~RUBY
      class T
        def initialize
          @t = nil
        end

        def alive
          @t.alive?
        end
      end
    RUBY

    expect(undefined_method_messages(source)).to include(/undefined method `alive\?' for nil/)
  end

  it "stays silent for a `&.` call whose non-nil constituent defines the method" do
    source = <<~RUBY
      def h(x)
        y = x ? "s" : nil
        y&.upcase
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "stays silent for a `&.` call on a nil-bearing union receiver" do
    # A `T | nil` union has no single concrete class, so the `call.undefined-method` rule already bails — and a `&.`
    # must not newly fire on the non-nil constituent (for a cross-file project def that would be a working-code false
    # positive). Only the pure-nil case is the bug N3 fixes.
    source = <<~RUBY
      def g(x)
        y = x ? 5 : nil
        y&.upcase
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "leaves a plain (non-safe-nav) nil-union receiver's diagnostics unchanged" do
    # Regression guard: the safe-nav narrowing must not touch the plain call path. A plain union receiver behaves
    # exactly as before.
    source = <<~RUBY
      def g(x)
        y = x ? 5 : nil
        y.upcase
      end
    RUBY

    # No undefined-method firing on the union (the `possible-nil-receiver` rule owns this site); the point is the
    # safe-nav path did not perturb it.
    expect(undefined_method_messages(source)).to be_empty
  end
end
