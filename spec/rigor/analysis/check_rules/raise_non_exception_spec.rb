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

  # The singleton/instance verdict asymmetry is deliberate and easy to "simplify" away in a refactor
  # (the rigor-rs port nearly did, twice — docs/notes/20260716-upstream-feedback.md item 4): a
  # `singleton(Object)` operand is EXACT knowledge (that one class object provably lacks `.exception`,
  # and both `:superclass` and `:disjoint` orderings are illegal), while an `Object`-TYPED instance is
  # not exact (the runtime value may well be an Exception), so the instance path excludes the generic
  # carriers and fires on `:disjoint` only.
  describe "singleton vs instance operand asymmetry (pinned)" do
    it "fires on `raise Object` — the singleton path treats :superclass ordering as illegal" do
      messages = raise_diagnostics("raise Object\n").map(&:message)
      expect(messages).to include(a_string_matching(/singleton\(Object\)/))
    end

    it "fires on `raise Class` (generic metaclass carrier is still an exact class object)" do
      expect(raise_diagnostics("raise Class\n")).not_to be_empty
    end

    it "fires on `raise Comparable` — a module constant orders :disjoint and has no .exception" do
      expect(raise_diagnostics("raise Comparable\n")).not_to be_empty
    end

    # #420 asked whether this silence is a real bound or a vestigial exclusion, since `raise Object.new`
    # does raise TypeError at run time. It is real, and the reason is that the rule never sees the
    # expression — it sees the carrier, and this carrier is shared with values that are NOT exact.
    # Measured: `Object.new` and a method declared `() -> Object` both type as exactly `Object`, so there
    # is no reading under which the first fires and the second stays silent. Converging the instance path
    # with the singleton one (allowing `:superclass`, AND dropping `Object` from
    # RAISE_UNEXACT_INSTANCE_CLASSES — both guards had to go, each was sufficient on its own) was tried
    # against a project fixture whose `() -> Object` method returns `ArgumentError.new`: it fires there,
    # on code that raises an ArgumentError at run time. AGENTS.md puts that cost above the worst-case
    # static reading. The demonstration is not an example here because this harness cannot express an
    # rbs-inline declared return — the fixture types as `Dynamic` and would pass either way.
    #
    # The corpus could not decide this and is recorded as such: `call.raise-non-exception` fires 0 / 2 /
    # 0 / 0 times on redmine, mastodon, mail and kramdown, and the convergence added zero firings to all
    # four — an absence, not a clearance, because the corpus contains no `raise <Object-typed value>`
    # site at all.
    #
    # The singleton path is different and stays as it is: `raise Object` names one exact class object,
    # `Object.exception` does not exist, and no subtype can intervene.
    it "stays silent on `raise Object.new` — an Object-typed INSTANCE is not exact knowledge" do
      expect(raise_diagnostics("raise Object.new\n")).to be_empty
    end
  end

  describe "first-operand shape (pinned)" do
    it "stays silent on bare keyword arguments (`raise(a: 1)` has no positional operand)" do
      expect(raise_diagnostics("raise(a: 1)\n")).to be_empty
    end

    it "fires on a braced Hash literal (`raise({ a: 1 })` is a positional Hash operand)" do
      expect(raise_diagnostics("raise({ a: 1 })\n")).not_to be_empty
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
