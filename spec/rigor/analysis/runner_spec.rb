# frozen_string_literal: true

require "rigor/analysis/runner"

# Path-error / parse-error specs intentionally bypass `analyze`
# because they exercise paths that do not exist or contain
# non-Ruby content; the helper assumes a writable tmpdir of
# `.rb` files. Everything else uses `analyze`.
RSpec.describe Rigor::Analysis::Runner do
  it "emits a diagnostic for a non-existent path instead of silently passing" do
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "ghost.rb")
      configuration = Rigor::Configuration.new("paths" => [missing])
      result = described_class.new(configuration: configuration).run

      expect(result).not_to be_success
      diag = result.diagnostics.first
      expect(diag.path).to eq(missing)
      expect(diag.message).to include("no such file")
    end
  end

  it "emits a diagnostic for a non-Ruby file path" do
    Dir.mktmpdir do |dir|
      txt = File.join(dir, "notes.txt")
      File.write(txt, "hello")
      configuration = Rigor::Configuration.new("paths" => [txt])
      result = described_class.new(configuration: configuration).run

      expect(result).not_to be_success
      expect(result.diagnostics.first.message).to include("not a Ruby file")
    end
  end

  it "reports Prism parse errors as diagnostics" do
    result = analyze("def broken\n")

    expect(result).not_to be_success
    expect(result.diagnostics.first.message).not_to be_empty
  end

  describe "CheckRules diagnostics (Slice 7 phase 8)" do
    it "flags an undefined method on a typed Constant receiver" do
      result = analyze("\"hello\".no_such_method\n")

      diag = result.diagnostics.find { |d| d.message.include?("no_such_method") }
      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:error)
      expect(diag.line).to eq(1)
    end

    it "does not flag a method that exists on the receiver class" do
      expect(analyze("[1, 2, 3].push(4)\n\"x\".upcase\n")).to be_success
    end

    it "does not flag implicit-self calls (the rule is explicit-receiver only)" do
      result = analyze(<<~RUBY)
        class Foo
          def bar
            helper(1)
          end

          def helper(_n); end
        end
      RUBY

      expect(result).to be_success
    end

    it "does not flag calls on Dynamic[Top] receivers" do
      expect(analyze("def f(x); x.anything; end\n")).to be_success
    end

    it "skips classes whose RBS definition cannot be built (constant-decl aliases like YAML)" do
      expect(analyze("YAML.dump({})\nYAML.safe_load_file(\"x\")\n")).to be_success
    end

    describe "wrong-arity rule (Slice 7 phase 11)" do
      it "flags too many positional arguments to a fixed-arity method" do
        result = analyze("[1, 2].rotate(1, 2)\n")

        diag = result.diagnostics.find { |d| d.message.include?("rotate") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("expected 0..1")
        expect(diag.message).to include("given 2")
      end

      it "flags too few positional arguments to a method with required args" do
        result = analyze("[1, 2].fetch\n")

        diag = result.diagnostics.find { |d| d.message.include?("fetch") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("expected 1..2")
        expect(diag.message).to include("given 0")
      end

      it "does not flag a call whose argument count fits the envelope" do
        expect(analyze("[1, 2, 3].rotate(1)\n[1].fetch(0)\n")).to be_success
      end

      it "skips calls with splat arguments (caller arity unknown)" do
        expect(analyze("args = [1]; [1].rotate(*args)\n")).to be_success
      end

      it "suppresses the diagnostic when the method is defined via def in source" do
        result = analyze(<<~RUBY)
          class String
            def my_extension; self; end
          end

          "x".my_extension
        RUBY

        expect(result).to be_success
      end

      it "suppresses the diagnostic when the method is defined via define_method" do
        result = analyze(<<~RUBY)
          class String
            define_method(:special) { |x| x }
          end

          "x".special(1)
        RUBY

        expect(result).to be_success
      end

      describe "diagnostic suppression (v0.0.2 #6)" do # rubocop:disable RSpec/NestedGroups
        it "skips rules listed in `disable:` of the configuration" do
          result = analyze("\"x\".no_method\n", config: { "disable" => ["undefined-method"] })

          expect(result).to be_success
        end

        it "honors a `# rigor:disable <rule>` comment on the same line" do
          result = analyze(%("x".no_method  # rigor:disable undefined-method\n))

          expect(result).to be_success
        end

        it "supports `# rigor:disable all` to suppress every rule on a line" do
          result = analyze(<<~RUBY)
            "x".no_method  # rigor:disable all
            [1].rotate(1, 2)  # not suppressed
          RUBY

          expect(result.diagnostics.size).to eq(1)
          expect(result.diagnostics.first.rule).to eq("wrong-arity")
        end
      end

      describe "argument-type-mismatch rule (v0.0.2 #4)" do # rubocop:disable RSpec/NestedGroups
        # `Demo#take_string: (String) -> String` fixture, paired
        # with the matching `def`. `analyze` writes the sig under
        # `sig/` and chdirs so `Environment.for_project` discovers
        # it.
        let(:demo_sig) do
          { "demo.rbs" => <<~RBS }
            class Demo
              def take_string: (String value) -> String
            end
          RBS
        end
        let(:demo_def) { <<~RUBY }
          class Demo
            def take_string(value); value; end
          end
        RUBY

        it "flags an Integer passed where a String is expected" do
          result = analyze("#{demo_def}Demo.new.take_string(42)\n", sig: demo_sig)

          mismatch = result.diagnostics.find { |d| d.message.start_with?("argument type mismatch") }
          expect(mismatch).not_to be_nil
          expect(mismatch.message).to include("expected String")
          expect(mismatch.message).to include("got 42")
        end

        it "stays silent on a matching call" do
          result = analyze(%(#{demo_def}Demo.new.take_string("hello")\n), sig: demo_sig)

          arg_errors = result.diagnostics.select { |d| d.message.start_with?("argument type mismatch") }
          expect(arg_errors).to be_empty
        end
      end

      describe "dump_type / assert_type rules (Slice 7 phase 19)" do # rubocop:disable RSpec/NestedGroups
        it "emits an info-severity diagnostic for `dump_type(value)`" do
          result = analyze(<<~RUBY)
            require "rigor/testing"
            include Rigor::Testing
            n = 4
            dump_type(n)
          RUBY

          dump = result.diagnostics.find { |d| d.message.start_with?("dump_type") }
          expect(dump).not_to be_nil
          expect(dump.severity).to eq(:info)
          expect(dump.message).to include("4")
          # info-severity does not fail the run.
          expect(result).to be_success
        end

        it "errors on `assert_type` mismatch and stays silent on a match" do # rubocop:disable RSpec/ExampleLength
          result = analyze(files: {
                             "match.rb" => <<~RUBY,
                               require "rigor/testing"
                               include Rigor::Testing
                               x = 4
                               assert_type("4", x)
                             RUBY
                             "miss.rb" => <<~RUBY
                               require "rigor/testing"
                               include Rigor::Testing
                               x = 4
                               assert_type("Integer", x)
                             RUBY
                           })

          mismatch = result.diagnostics.find { |d| d.message.start_with?("assert_type mismatch") }
          expect(mismatch).not_to be_nil
          expect(mismatch.path).to end_with("miss.rb")
          expect(mismatch.message).to include('expected "Integer"')
          expect(mismatch.message).to include('got "4"')
        end
      end

      describe "nil-receiver rule (Slice 7 phase 14)" do # rubocop:disable RSpec/NestedGroups
        let(:maybe_nil_string) do
          <<~RUBY
            x = if rand < 0.5
              "hello"
            else
              nil
            end
          RUBY
        end

        it "flags a call to a method that does not exist on NilClass when receiver is T | nil" do
          result = analyze("#{maybe_nil_string}x.upcase\n")

          diag = result.diagnostics.find { |d| d.message.include?("nil receiver") }
          expect(diag).not_to be_nil
          expect(diag.message).to include("upcase")
        end

        it "does not flag a method that NilClass also has (e.g. to_s)" do
          expect(analyze("#{maybe_nil_string}x.to_s\n")).to be_success
        end

        it "does not flag safe-navigation calls (`x&.method`)" do
          expect(analyze("#{maybe_nil_string}x&.upcase\n")).to be_success
        end

        it "is suppressed when an early-return guard narrows nil out (Slice 7 phase 14 narrowing)" do
          result = analyze(<<~RUBY)
            def go(_)
              x = if rand < 0.5
                "hello"
              else
                nil
              end
              return if x.nil?
              x.upcase
            end
          RUBY

          expect(result).to be_success
        end
      end

      it "skips methods with required keyword arguments" do
        expect(analyze("[1, 2].push(1)\n")).to be_success
      end
    end
  end

  describe "explain mode (v0.0.2 #10)" do
    it "is silent by default" do
      result = analyze("x = 1\n")

      expect(result.diagnostics.select { |d| d.rule == "fallback" }).to be_empty
    end

    it "emits :info fallback diagnostics when explain is on" do
      # `BEGIN { ... }` is a Prism::PreExecutionNode the engine
      # does not recognise — a stable explain-mode trigger.
      result = analyze("BEGIN { 1 }\n", explain: true)

      fallback = result.diagnostics.find { |d| d.rule == "fallback" }
      expect(fallback).not_to be_nil
      expect(fallback.severity).to eq(:info)
      expect(fallback.message).to include("fail-soft fallback")
      expect(result).to be_success # info doesn't fail the run
    end
  end
end
