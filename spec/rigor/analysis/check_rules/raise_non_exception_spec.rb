# frozen_string_literal: true

require "spec_helper"

# `call.raise-non-exception` — `raise x` / `fail x` where the first argument's inferred type is provably
# not a legal raise operand (an Exception class, an Exception instance, a String, or an object whose class
# defines `#exception`). PHPStan ThrowExprTypeRule analogue. FP-discipline envelope: fires only on a
# concrete verdict — Dynamic / unknown / union-with-a-legal-arm stay silent, explicit-receiver `raise`
# calls are user methods, and a project-side `raise` redefinition silences the rule.
RSpec.describe "raise non-exception operand" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def raise_diagnostics(source)
    diagnostics_for(source).select { |d| d.rule == "call.raise-non-exception" }
  end

  describe "firing cases" do
    it "fires on raise with an Integer literal" do
      messages = raise_diagnostics("raise 42\n").map(&:message)
      expect(messages).to include(a_string_matching(/raise' operand types as .*42.*TypeError at runtime/))
    end

    it "fires on raise with a Symbol literal" do
      expect(raise_diagnostics("raise :not_an_error\n")).not_to be_empty
    end

    it "fires on raise with an explicit nil literal argument" do
      # `raise nil` is a TypeError (only BARE `raise` re-raises $!).
      expect(raise_diagnostics("raise nil\n")).not_to be_empty
    end

    it "fires on raise with an Array literal" do
      expect(raise_diagnostics("raise [1, 2]\n")).not_to be_empty
    end

    it "fires on fail with an illegal operand" do
      expect(raise_diagnostics("fail 3.14\n")).not_to be_empty
    end

    it "fires inside a method body" do
      source = <<~RUBY
        class Widget
          def explode
            raise 42
          end
        end
      RUBY
      expect(raise_diagnostics(source)).not_to be_empty
    end
  end

  describe "legal operands (silent)" do
    it "does not fire on an Exception class" do
      expect(raise_diagnostics(%(raise ArgumentError\n))).to be_empty
    end

    it "does not fire on an Exception class with a message" do
      expect(raise_diagnostics(%(raise ArgumentError, "bad input"\n))).to be_empty
    end

    it "does not fire on a String message" do
      expect(raise_diagnostics(%(raise "something went wrong"\n))).to be_empty
    end

    it "does not fire on an Exception instance" do
      expect(raise_diagnostics(%(raise ArgumentError.new("bad")\n))).to be_empty
    end

    it "does not fire on a project-defined exception subclass instance" do
      source = <<~RUBY
        class CustomError < StandardError
        end

        raise CustomError.new("boom")
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end

    it "does not fire on bare raise" do
      source = <<~RUBY
        def retry_it
          yield
        rescue StandardError
          raise
        end
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end
  end

  describe "uncertainty (silent)" do
    it "does not fire when the argument is untyped / Dynamic" do
      source = <<~RUBY
        def rethrow(error)
          raise error
        end
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end

    it "does not fire on a union with a legal arm" do
      source = <<~RUBY
        x = rand > 0.5 ? 42 : "message"
        raise x
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end

    it "fires on a union whose every arm is illegal" do
      source = <<~RUBY
        x = rand > 0.5 ? 42 : :sym
        raise x
      RUBY
      expect(raise_diagnostics(source)).not_to be_empty
    end

    it "does not fire when the argument's class defines #exception" do
      source = <<~RUBY
        class Wrapper
          def exception
            RuntimeError.new("wrapped")
          end
        end

        raise Wrapper.new
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end
  end

  describe "raise-shadowing (silent)" do
    it "does not fire on an explicit-receiver raise call" do
      source = <<~RUBY
        class Rocket
          def raise(altitude)
            altitude
          end
        end

        Rocket.new.raise(42)
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end

    it "does not fire when the enclosing class redefines raise" do
      source = <<~RUBY
        class Elevator
          def raise(floors)
            floors
          end

          def go_up
            raise 3
          end
        end
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end

    it "does not fire when a toplevel def redefines raise" do
      source = <<~RUBY
        def raise(level)
          level
        end

        raise 42
      RUBY
      expect(raise_diagnostics(source)).to be_empty
    end
  end

  describe "suppression" do
    it "honours an in-source rigor:disable comment" do
      expect(raise_diagnostics("raise 42 # rigor:disable call.raise-non-exception\n")).to be_empty
    end

    it "honours the legacy unprefixed alias" do
      expect(raise_diagnostics("raise 42 # rigor:disable raise-non-exception\n")).to be_empty
    end
  end
end
