# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-24 slice 4 — `call.self-undefined-method`. The rule consumes the
# engine's recorded unresolved implicit-self calls and fires only on a
# confidently-closed standalone project class. It ships `:off` in every
# profile, so the specs opt in via `severity_overrides:`.
RSpec.describe "call.self-undefined-method rule" do
  def firings(source, enable: true)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "code.rb"), source)
      config = { "paths" => [dir] }
      config["severity_overrides"] = { "call.self-undefined-method" => "warning" } if enable
      result = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new(config), cache_store: nil
      ).run
      result.diagnostics.select { |d| d.rule == "call.self-undefined-method" }.map(&:method_name)
    end
  end

  it "fires on a typo'd implicit-self call in a standalone class" do
    expect(firings(<<~RUBY)).to include(:compute_totl)
      class Widget
        def price
          compute_totl
        end

        def compute_total
          100
        end
      end
    RUBY
  end

  it "does not fire when the called sibling method exists" do
    expect(firings(<<~RUBY)).to be_empty
      class Widget
        def price
          compute_total
        end

        def compute_total
          100
        end
      end
    RUBY
  end

  it "is off by default (no override) even with a real typo" do
    expect(firings(<<~RUBY, enable: false)).to be_empty
      class Widget
        def price
          compute_totl
        end
      end
    RUBY
  end

  it "does not fire inside a module (a mixin contract)" do
    expect(firings(<<~RUBY)).to be_empty
      module Helper
        def run
          missing_helper_method
        end
      end
    RUBY
  end

  it "does not fire on a class with a superclass (surface extends beyond the file)" do
    expect(firings(<<~RUBY)).to be_empty
      class Base
      end

      class Child < Base
        def go
          inherited_maybe
        end
      end
    RUBY
  end

  it "does not fire on a class that includes a module" do
    expect(firings(<<~RUBY)).to be_empty
      module Mixin
      end

      class Host
        include Mixin

        def go
          provided_by_mixin_maybe
        end
      end
    RUBY
  end

  it "does not fire on a class defining method_missing" do
    expect(firings(<<~RUBY)).to be_empty
      class Proxy
        def call_it
          anything_goes
        end

        def method_missing(name, *args)
          nil
        end
      end
    RUBY
  end

  it "does not fire on a class with a dynamic attr_reader splat" do
    expect(firings(<<~RUBY)).to be_empty
      class Record
        SLOTS = %i[a b].freeze
        attr_reader(*SLOTS)

        def describe
          a
        end
      end
    RUBY
  end

  it "does not fire on a `class X < Data.define(...)` member read" do
    expect(firings(<<~RUBY)).to be_empty
      class Money < Data.define(:amount)
        def describe
          amount
        end
      end
    RUBY
  end
end
