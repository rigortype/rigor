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

  it "does not fire on a method an abstract base's subclass implements (template-method hook)" do
    # Mail::CommonField#decoded calls `do_decode`, defined by every
    # `< CommonField` subclass; Mail::Retriever#find by POP3 / IMAP. A base
    # that calls a method its subclasses supply is a template-method hook, not
    # a typo. (WD4 corpus eval, Bucket 2 — the abstract-base pattern.)
    expect(firings(<<~RUBY)).to be_empty
      class CommonField
        def decoded
          do_decode
        end
      end

      class UnstructuredField < CommonField
        def do_decode
          "x"
        end
      end
    RUBY
  end

  it "still fires on a genuine typo even when a subclass exists" do
    # The subclass gate must suppress only the exact missed name — a real typo
    # (`do_decodee`) that no subclass defines still fires.
    expect(firings(<<~RUBY)).to include(:do_decodee)
      class CommonField
        def decoded
          do_decodee
        end
      end

      class UnstructuredField < CommonField
        def do_decode
          "x"
        end
      end
    RUBY
  end

  it "does not fire on a class with a dynamic (non-constant) superclass" do
    # `class X < DelegateClass(Array)` / `< Struct.new(...)` inherits a
    # dynamically produced surface the engine cannot enumerate from a constant
    # name, so a missed self-call is not provably a typo.
    expect(firings(<<~RUBY)).to be_empty
      class PartsList < DelegateClass(Array)
        def collect_each
          each { |x| x }
        end
      end
    RUBY
  end

  it "does not fire on a universal base (Object / BasicObject) — a self-type fallback, not a typo" do
    # An implicit-self miss tagged `Object` / `BasicObject` means the engine
    # fell back to the root self-type because it could not resolve the real
    # class (a `class << self` / metaprogramming surface). Their method set is
    # never project-complete, so a miss there is a resolution gap. (WD4 corpus
    # eval: the dominant false-positive class — protobuf / tdiary, ~357 firings.)
    expect(firings(<<~RUBY)).to be_empty
      class Object
        def my_helper
          definitely_undefined_xyz
        end
      end
    RUBY
    expect(firings(<<~RUBY)).to be_empty
      class BasicObject
        def my_helper
          definitely_undefined_xyz
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
