# frozen_string_literal: true

require "rigor/analysis/runner"
require "rigor/analysis/baseline"

# Split out of `runner_spec.rb`, which at 5,955 lines weighed ~167s and so exceeded what one binpacker
# worker may hold: a spec FILE is the scheduling unit, so the file alone set the CI matrix's makespan
# (see the shard rationale in .github/workflows/ci.yml). This block was 65% of that cost on its own.
#
# The `describe` wrapper is kept verbatim rather than flattened into this file's top level, so every
# example's full name is unchanged — `--example` filters and binpacker's timing history keep matching.
RSpec.describe Rigor::Analysis::Runner do
  describe "CheckRules diagnostics (Slice 7 phase 8)" do
    it "flags an undefined method on a typed Constant receiver" do
      result = analyze("\"hello\".no_such_method\n")

      diag = result.diagnostics.find { |d| d.message.include?("no_such_method") }
      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:error)
      expect(diag.line).to eq(1)
    end

    it "carries structured receiver_type / method_name on the undefined-method diagnostic (ADR-23 slice 4)" do
      result = analyze("\"hello\".no_such_method\n")

      # `receiver_type` stores the rendered receiver type — the same token the message uses; the triage catalogue
      # normalises it.
      diag = result.diagnostics.find { |d| d.rule == "call.undefined-method" }
      expect([diag&.receiver_type, diag&.method_name]).to eq(['"hello"', "no_such_method"])
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

      describe "diagnostic suppression (v0.0.2 #6)" do
        it "skips rules listed in `disable:` of the configuration" do
          result = analyze("\"x\".no_method\n", config: { "disable" => ["call.undefined-method"] })

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
          expect(result.diagnostics.first.rule).to eq("call.wrong-arity")
        end

        # ADR-8 § "Diagnostic ID family hierarchy"
        it "honours legacy unprefixed disable identifiers" do
          legacy = analyze("\"x\".no_method\n", config: { "disable" => ["undefined-method"] })
          expect(legacy).to be_success
        end

        it "supports family-wildcard disable tokens (`call` disables every call.* rule)" do
          src = "\"x\".no_method\n[1].rotate(1, 2)\n"
          # Both diagnostics fire under default config
          baseline = analyze(src)
          expect(baseline.diagnostics.map(&:rule)).to include("call.undefined-method", "call.wrong-arity")
          # `call` family wildcard suppresses both
          wild = analyze(src, config: { "disable" => ["call"] })
          expect(wild).to be_success
        end

        it "honours a family-wildcard `# rigor:disable call` comment on the same line" do
          result = analyze(%("x".no_method  # rigor:disable call\n))
          expect(result).to be_success
        end

        it "honours a `# rigor:disable-file <rule>` comment on every line" do
          result = analyze(<<~RUBY)
            # rigor:disable-file undefined-method
            "x".no_method
            "y".another_missing_method
          RUBY
          expect(result).to be_success
        end

        it "honours `# rigor:disable-file all` (entire-file every-rule suppression)" do
          result = analyze(<<~RUBY)
            # rigor:disable-file all
            "x".no_method
            5 / 0
          RUBY
          expect(result).to be_success
        end

        it "respects file-suppression placed at the bottom of the file" do
          # The convention is to put the comment near the top, but Rigor scans every comment in the file so any
          # placement works.
          result = analyze(<<~RUBY)
            "x".no_method
            "y".also_missing
            # rigor:disable-file undefined-method
          RUBY
          expect(result).to be_success
        end

        it "does not confuse `disable-file` with the line-only `disable`" do
          # Per-line suppression on line 1 only; line 2's diagnostic still fires.
          result = analyze(<<~RUBY)
            "x".no_method # rigor:disable undefined-method
            "y".also_missing
          RUBY
          undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
          expect(undefined.size).to eq(1)
          expect(undefined.first.line).to eq(2)
        end

        it "expands family wildcards inside disable-file" do
          result = analyze(<<~RUBY)
            # rigor:disable-file call
            "x".no_method
            5 / 0
          RUBY
          undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
          expect(undefined).to be_empty
        end
      end

      # PHPStan-IgnoreParseErrorRule-modelled suppression-marker validation: a broken suppression comment
      # must not silently no-op. Matching semantics stay untouched (unknown tokens are still kept verbatim);
      # these specs cover only the additive surveillance diagnostics.
      describe "suppression marker validation (suppression.*)" do
        def suppression_diagnostics(result)
          result.diagnostics.select { |d| d.rule&.start_with?("suppression.") }
        end

        it "warns on an unknown rule token, carrying the token verbatim at the comment's line" do
          result = analyze(%(x = 1 # rigor:disable no-such-rule\n))

          warning = suppression_diagnostics(result)
          expect(warning.size).to eq(1)
          expect(warning.first.rule).to eq("suppression.unknown-rule")
          expect(warning.first.severity).to eq(:warning)
          expect(warning.first.message).to include("`no-such-rule`")
          expect(warning.first.line).to eq(1)
        end

        it "warns on a typo'd canonical id (`call.undefined-metod`)" do
          result = analyze(%("x".no_method # rigor:disable call.undefined-metod\n))

          warning = suppression_diagnostics(result)
          expect(warning.map(&:rule)).to eq(["suppression.unknown-rule"])
          expect(warning.first.message).to include("`call.undefined-metod`")
          # The typo'd token suppresses nothing, so the original diagnostic still fires.
          expect(result.diagnostics.map(&:rule)).to include("call.undefined-method")
        end

        it "does not warn on canonical ids, legacy aliases, `all`, family wildcards, plugin ids, or engine ids" do
          result = analyze(<<~RUBY)
            a = "x".no_method # rigor:disable call.undefined-method
            b = "x".no_method # rigor:disable undefined-method
            c = "x".no_method # rigor:disable all
            d = "x".no_method # rigor:disable call
            e = 1 # rigor:disable plugin.anything.goes
            f = 2 # rigor:disable rbs_extended.unsatisfied-conformance
            g = 3 # rigor:disable dynamic.rbs-extended.unresolved, load-error
            [a, b, c, d, e, f, g]
          RUBY

          expect(suppression_diagnostics(result)).to be_empty
        end

        it "warns on an empty `# rigor:disable` marker" do
          result = analyze("x = 1 # rigor:disable\n")

          warning = suppression_diagnostics(result)
          expect(warning.map(&:rule)).to eq(["suppression.empty"])
          expect(warning.first.severity).to eq(:warning)
        end

        it "warns on an empty `# rigor:disable-file` marker and on unknown disable-file tokens" do
          result = analyze(<<~RUBY)
            # rigor:disable-file
            # rigor:disable-file call.undefined-metod
            x = 1
          RUBY

          rules = suppression_diagnostics(result).map(&:rule).sort
          expect(rules).to eq(["suppression.empty", "suppression.unknown-rule"])
        end

        it "warns on the RuboCop-reflex `# rigor:disable-next-line` marker" do
          result = analyze(%("x".no_method # rigor:disable-next-line call.undefined-method\n))

          warning = suppression_diagnostics(result)
          expect(warning.map(&:rule)).to eq(["suppression.unknown-marker"])
          expect(warning.first.severity).to eq(:warning)
          expect(warning.first.message).to include("`rigor:disable-next-line`")
          # The unrecognised marker suppresses nothing — the original diagnostic still fires.
          expect(result.diagnostics.map(&:rule)).to include("call.undefined-method")
        end

        it "warns on `# rigor:enable` (Rigor has no enable form) and on a token-less unknown marker" do
          result = analyze(<<~RUBY)
            x = 1 # rigor:enable call.undefined-method
            y = 2 # rigor:disable-next-line
            [x, y]
          RUBY

          warnings = suppression_diagnostics(result)
          expect(warnings.map(&:rule)).to eq(%w[suppression.unknown-marker suppression.unknown-marker])
          expect(warnings.map(&:line)).to eq([1, 2])
        end

        it "leaves prose mentioning an unknown marker alone" do
          result = analyze(<<~RUBY)
            # `# rigor:disable-next-line` is not supported; use `# rigor:disable <rule>` instead.
            x = 1
          RUBY

          expect(suppression_diagnostics(result)).to be_empty
        end

        it "keeps `suppression.unknown-marker` suppressible like its siblings" do
          result = analyze(<<~RUBY)
            # rigor:disable-file suppression.unknown-marker
            x = 1 # rigor:enable call.undefined-method
            x
          RUBY

          expect(suppression_diagnostics(result)).to be_empty
        end

        it "treats prose mentioning the marker followed by non-token text as an ordinary comment" do
          result = analyze(<<~RUBY)
            # Use `# rigor:disable <rule1>, <rule2>` on the offending line.
            # The file-wide form is `# rigor:disable-file <rules>`.
            x = 1
          RUBY

          expect(suppression_diagnostics(result)).to be_empty
        end

        it "is itself suppressible on the same line without regress" do
          result = analyze(%(x = 1 # rigor:disable no-such-rule, suppression.unknown-rule\n))

          expect(suppression_diagnostics(result)).to be_empty
        end

        it "is suppressible file-wide via `# rigor:disable-file suppression`" do
          result = analyze(<<~RUBY)
            # rigor:disable-file suppression
            x = 1 # rigor:disable no-such-rule
            y = 2 # rigor:disable
            [x, y]
          RUBY

          expect(suppression_diagnostics(result)).to be_empty
        end

        it "is disable-able via the configuration `disable:` list" do
          result = analyze(%(x = 1 # rigor:disable no-such-rule\n),
                           config: { "disable" => ["suppression.unknown-rule"] })

          expect(suppression_diagnostics(result)).to be_empty
        end

        it "honours a `severity_overrides:` entry (`off` drops it, `error` promotes it)" do
          off = analyze(%(x = 1 # rigor:disable no-such-rule\n),
                        config: { "severity_overrides" => { "suppression.unknown-rule" => "off" } })
          expect(suppression_diagnostics(off)).to be_empty

          promoted = analyze(%(x = 1 # rigor:disable no-such-rule\n),
                             config: { "severity_overrides" => { "suppression.unknown-rule" => "error" } })
          expect(suppression_diagnostics(promoted).map(&:severity)).to eq([:error])
        end

        it "is absorbed by a baseline like any other rule" do
          result = analyze(%(x = 1 # rigor:disable no-such-rule\n))
          warnings = suppression_diagnostics(result)
          expect(warnings).not_to be_empty

          baseline = Rigor::Analysis::Baseline.from_diagnostics(warnings)
          surfaced, silenced_count = baseline.filter(warnings)
          expect(surfaced).to be_empty
          expect(silenced_count).to eq(warnings.size)
        end
      end

      # ADR-8 § "`def.return-type-mismatch` rule"
      describe "def.return-type-mismatch rule" do
        let(:demo_sig) do
          { "demo.rbs" => <<~RBS }
            class Demo
              def returns_string: () -> String
              def returns_int_or_nil: () -> Integer?
            end
          RBS
        end

        it "stays silent when the body's last expression matches the declared return type" do
          src = <<~RUBY
            class Demo
              def returns_string
                "hi"
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        it "flags a body whose inferred type cannot satisfy the declared return type" do
          src = <<~RUBY
            class Demo
              def returns_string
                42
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          mismatch = result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }
          expect(mismatch).not_to be_nil
          expect(mismatch.message).to include("returns_string")
          expect(mismatch.message).to include("declared String")
        end

        it "skips bodies whose inferred type is Dynamic[top] (analyzer fail-soft)" do
          src = <<~RUBY
            class Demo
              def returns_string
                some_unknown_helper
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        it "skips methods that have no RBS sig (no contract to violate)" do
          src = <<~RUBY
            class Demo
              def no_sig_method
                42
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        it "is suppressible via `# rigor:disable def.return-type-mismatch`" do
          src = <<~RUBY
            class Demo
              def returns_string  # rigor:disable def.return-type-mismatch
                42
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        describe "refinement carrier override (v0.1.2)" do
          let(:refined_sig) do
            { "refined.rbs" => <<~RBS }
              class Refined
                %a{rigor:v1:return: non-empty-string}
                def name: () -> String

                %a{rigor:v1:return: positive-int}
                def count: () -> Integer
              end
            RBS
          end

          it "fires when the body returns the empty string against `non-empty-string`" do
            src = <<~RUBY
              class Refined
                def name
                  ""
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            mismatch = result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }
            expect(mismatch).not_to be_nil
            expect(mismatch.message).to include("name")
          end

          it "stays silent when the body satisfies `non-empty-string`" do
            src = <<~RUBY
              class Refined
                def name
                  "Alice"
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
          end

          it "fires when the body returns 0 against `positive-int`" do
            src = <<~RUBY
              class Refined
                def count
                  0
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            mismatch = result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }
            expect(mismatch).not_to be_nil
            expect(mismatch.message).to include("count")
          end

          it "stays silent when the body satisfies `positive-int`" do
            src = <<~RUBY
              class Refined
                def count
                  42
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
          end
        end
      end

      # ADR-8 § "Severity profile"
      describe "severity profile re-stamping (v0.1.0+)" do
        it "lenient profile drops call.argument-type-mismatch to :warning" do
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, "demo.rbs"), <<~RBS)
              class Demo
                def take_string: (String value) -> String
              end
            RBS
            FileUtils.mkdir_p(File.join(dir, "sig"))
            FileUtils.mv(File.join(dir, "demo.rbs"), File.join(dir, "sig"))
            File.write(File.join(dir, "use.rb"), <<~RUBY)
              class Demo
                def take_string(value); value; end
              end
              Demo.new.take_string(42)
            RUBY
            Dir.chdir(dir) do
              configuration = Rigor::Configuration.new(
                Rigor::Configuration::DEFAULTS.merge(
                  "paths" => ["use.rb"], "severity_profile" => "lenient"
                )
              )
              result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
              mismatch = result.diagnostics.find { |d| d.rule == "call.argument-type-mismatch" }
              expect(mismatch).not_to be_nil
              expect(mismatch.severity).to eq(:warning)
            end
          end
        end

        it "severity_overrides off drops the diagnostic entirely" do
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, "use.rb"), "\"x\".no_method\n")
            Dir.chdir(dir) do
              configuration = Rigor::Configuration.new(
                Rigor::Configuration::DEFAULTS.merge(
                  "paths" => ["use.rb"],
                  "severity_overrides" => { "call.undefined-method" => "off" }
                )
              )
              result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
              expect(result.diagnostics.find { |d| d.rule == "call.undefined-method" }).to be_nil
            end
          end
        end
      end

      describe "argument-type-mismatch rule (v0.0.2 #4)" do
        # `Demo#take_string: (String) -> String` fixture, paired with the matching `def`. `analyze` writes the sig under
        # `sig/` and chdirs so `Environment.for_project` discovers it.
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

        # ADR-58 (N2 extension, 2026-06-13 app/network survey) — the declaration-sourced-nil-is-not-diagnostic-fuel
        # criterion that governs `possible-nil-receiver` extends to `argument-type-mismatch`. A declaration-sourced ivar
        # (the class-ivar index seed of a ctor `@x = 0` / `@x = nil`, read in a sibling method) types `T | nil`; the
        # rejecting constituent is the seed nil, and the program's invariant is that the ivar is set by then. Stripping
        # the nil yields an accepted type, so the rule withholds. Flow-live nil and genuinely-wrong types keep firing.
        context "when the rejecting argument is a declaration-sourced ivar nil (ADR-58 N2)" do
          def arg_mismatch_diags(result)
            result.diagnostics.select { |d| d.message.start_with?("argument type mismatch") }
          end

          it "does not fire on `@length` (ctor-seeded Integer ivar) used in `k <= @length`" do
            # `@length = 0` in the ctor seeds the class-ivar index, so a read in a sibling method types `0 | nil`.
            # `Integer#<=` expects Numeric; `0` is gradual-consistent, the seed `nil` is what rejects. (concurrent-ruby
            # ruby_non_concurrent_priority_queue shape.)
            result = analyze(<<~RUBY)
              class PQ
                def initialize; @length = 0; end
                def push; @length += 1; end
                def covers?
                  k = 1
                  k <= @length
                end
              end
            RUBY
            expect(arg_mismatch_diags(result)).to be_empty
          end

          it "STILL fires on a flow-live nil argument (method-local @x = nil drops the mark)" do
            result = analyze(<<~RUBY)
              class PQ
                def initialize; @length = 0; end
                def covers?
                  k = 1
                  @length = nil
                  k <= @length
                end
              end
            RUBY
            expect(arg_mismatch_diags(result)).not_to be_empty
          end

          it "STILL fires on a genuinely-wrong argument type regardless of provenance" do
            # `@name` is a ctor-seeded String ivar — declaration-sourced — but passing a String where Numeric is
            # required is a real mismatch with no nil constituent to strip, so it must still fire.
            result = analyze(<<~RUBY)
              class PQ
                def initialize; @name = "q"; end
                def covers?
                  k = 1
                  k <= @name
                end
              end
            RUBY
            expect(arg_mismatch_diags(result)).not_to be_empty
          end
        end
      end

      describe "dump_type / assert_type rules (Slice 7 phase 19)" do
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

        it "errors on `assert_type` mismatch and stays silent on a match" do
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

      describe "nil-receiver rule (Slice 7 phase 14)" do
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

        it "is suppressed when an ivar nil-guard fires on an ivar seeded as Constant[nil]" do
          # Regression: when @ivar is seeded Constant[nil] by the class-ivar accumulator, @ivar.nil? folds to
          # Constant[true] (always-live branch optimisation). The fix ensures the early-return narrowing path still
          # applies so downstream code doesn't see the stale nil type.
          result = analyze(<<~RUBY)
            class GuardedService
              def initialize
                @event = nil
              end

              def run
                return if @event.nil?
                @event.process
              end
            end
          RUBY

          expect(result).to be_success
        end
      end

      # Regression — liquid v5.x sweep, Event 3 (docs/notes/20260616-liquid-v5.x-regression-sweep.md). A local
      # conditionally assigned across an `if/elsif/else: raise` chain is bound on every reachable path (the else
      # raises), so reading it afterwards must NOT fire `possible-nil-receiver`. The bug only surfaced when one
      # assigning arm was `Dynamic`-typed and another concrete: the inner `elsif … else raise` dropped its body's
      # assignment, leaving the local unbound for the outer if's join to nil-inject. The `Dynamic | concrete` union then
      # leaked the injected nil past the FP-discipline gate that silences a *bare* `Dynamic` receiver. The fix carries
      # the surviving then-body's scope forward; the whole bisection table must stay clean.
      describe "if/elsif/else-raise conditional-local definite assignment" do
        def nil_receiver_diags(result)
          result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        end

        it "2-arm if/else-raise, single concrete arm → clean" do
          result = analyze(<<~RUBY)
            def m(n)
              if n.is_a?(String) then partial = n.to_s
              else raise ::ArgumentError end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "3-arm if/elsif/else-raise, two concrete arms → clean" do
          result = analyze(<<~RUBY)
            def m(t, n)
              if t.is_a?(String) then partial = t.to_s
              elsif n.is_a?(String) then partial = n.to_s
              else raise ::ArgumentError end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "3-arm if/elsif/else-raise, one Dynamic + one concrete arm → clean (the bug)" do
          result = analyze(<<~RUBY)
            def m(t, n)
              if t then partial = t.anything
              elsif n.is_a?(String) then partial = n.to_s
              else raise ::ArgumentError end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "bare Dynamic receiver (no conditional) → clean" do
          result = analyze(<<~RUBY)
            def m(t)
              partial = t.anything
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "2-arm if/else (no raise), Dynamic-or-concrete → clean" do
          result = analyze(<<~RUBY)
            def m(t, n)
              if t then partial = t.anything
              else partial = n.to_s end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end
      end

      it "skips methods with required keyword arguments" do
        expect(analyze("[1, 2].push(1)\n")).to be_success
      end
    end

    describe "unreachable-branch rule (v0.1.2)" do
      it "flags the else branch when the if predicate is the `true` literal" do
        result = analyze(<<~RUBY)
          if true
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "flags the then branch when the if predicate is the `false` literal" do
        result = analyze(<<~RUBY)
          if false
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always falsey")
      end

      it "flags a postfix-if body when the predicate is `false`" do
        result = analyze("puts \"never\" if false\n")
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
      end

      it "flags the body when an unless predicate is the `true` literal" do
        result = analyze(<<~RUBY)
          unless true
            x = 1
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "flags the else branch in a ternary expression with a literal predicate" do
        result = analyze("x = true ? 1 : 2\n")
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
      end

      it "treats `if nil` as always falsey" do
        result = analyze(<<~RUBY)
          if nil
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always falsey")
      end

      it "treats numeric / string / symbol literals as always truthy (Ruby semantics)" do
        result = analyze(<<~RUBY)
          if 0
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "does not flag inferred-constant predicates (envelope is literal-only)" do
        # `class_object.name.nil?` folds to `Constant<false>` because RBS declares `Module#name -> String`, but
        # anonymous classes really do return nil at runtime. The literal-only envelope avoids flagging the defensive
        # `raise ... if x.name.nil?` shape.
        result = analyze(<<~RUBY)
          def register(class_object)
            raise ArgumentError unless class_object.is_a?(Module)
            raise ArgumentError, "anonymous" if class_object.name.nil?

            class_object.name
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end

      it "does not flag when the predicate is a non-literal expression" do
        result = analyze(<<~RUBY)
          n = ARGV.first&.to_i || 0
          if n > 0
            x = 1
          else
            x = 2
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end

      it "does not flag `if true; ...; end` with no else (no observable dead branch)" do
        result = analyze(<<~RUBY)
          if true
            x = 1
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end

      it "is suppressible via `# rigor:disable unreachable-branch` on the dead-branch line" do
        # The diagnostic points at the dead branch's location, so the suppression comment lives on the dead-branch
        # statement (not the `if` line).
        result = analyze(<<~RUBY)
          if false
            x = 1 # rigor:disable unreachable-branch
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end
    end

    describe "always-truthy-condition rule (v0.1.2)" do
      def truthy_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }
      end

      it "flags an `if` whose predicate is an inferred Constant" do
        result = analyze(<<~RUBY)
          x = 1
          if x
            "yes"
          else
            "no"
          end
        RUBY
        diag = truthy_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "does not double-fire on a syntactic literal predicate (covered by unreachable-branch)" do
        result = analyze(<<~RUBY)
          if true
            x = 1
          else
            x = 2
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire on `.nil?` (defensive predicate skip)" do
        result = analyze(<<~RUBY)
          name = "Alice"
          if name.nil?
            "missing"
          else
            "ok"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      # Issue #313 — a nil guard on a literal-hash lookup with a dynamic key. `MAP[:absent]` really is nil at
      # runtime; the read omits `nil` only because pessimising it costs more false positives than the miss it
      # models, so nothing folded from it is proof. The `.nil?` skip above covers the bare form by syntax
      # alone, which is why only the composed spellings ever surfaced this.
      describe "optimistically nil-free carriers" do
        let(:rank_table) { "MAP = { public: 2, protected: 1, private: 0 }.freeze\n" }

        it "does not fire on a bare `.nil?` guard over the lookup" do
          result = analyze(<<~RUBY)
            #{rank_table}
            def rank(a)
              x = MAP[a]
              return false if x.nil?

              x
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on a `||` composition of two such guards" do
          result = analyze(<<~RUBY)
            #{rank_table}
            def reduced?(a, b)
              x = MAP[a]
              y = MAP[b]
              return false if x.nil? || y.nil?

              x < y
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on a `&&` composition of two negated guards" do
          result = analyze(<<~RUBY)
            #{rank_table}
            def reduced?(a, b)
              x = MAP[a]
              y = MAP[b]
              return false unless !x.nil? && !y.nil?

              x < y
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire when the lookup is the predicate itself" do
          # A uniform-valued table reads as a lone `Constant`, so the rule's `Constant` test cannot tell this
          # from a proof — the shape that made the exclusion unenforceable without provenance.
          result = analyze(<<~RUBY)
            UNIFORM = { public: 1, protected: 1 }.freeze
            def known?(a)
              return false if UNIFORM[a]

              true
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "still fires on a composed guard over proof-carrying carriers (the control)" do
          result = analyze(<<~RUBY)
            def both_present?
              s = "a"
              t = "b"
              return false if s.nil? || t.nil?

              true
            end
          RUBY
          expect(truthy_diags(result).map(&:message)).to include(a_string_including("always falsey"))
        end

        it "still fires on a composed guard over static-key reads, which cannot miss (the control)" do
          result = analyze(<<~RUBY)
            #{rank_table}
            def fixed_pair
              x = MAP[:public]
              y = MAP[:private]
              return false if x.nil? || y.nil?

              x < y
            end
          RUBY
          expect(truthy_diags(result).map(&:message)).to include(a_string_including("always falsey"))
        end
      end

      it "does not fire on `.empty?` (defensive predicate skip)" do
        result = analyze(<<~RUBY)
          arr = []
          if arr.empty?
            "no items"
          else
            "items"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire when the predicate sits inside a block (loop-mutation skip)" do
        result = analyze(<<~RUBY)
          [1, 2, 3].each do |x|
            shift = 7
            if shift
              x
            end
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire when the predicate sits inside a `while` loop" do
        result = analyze(<<~RUBY)
          x = 1
          while x
            break
          end
        RUBY
        # `while x` itself isn't an IfNode so it's outside the rule's scope; if Rigor ever folds the body's `if` against
        # a loop-mutated local, the loop ancestor check keeps the rule from firing.
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire on a non-constant predicate (Union / Dynamic etc.)" do
        result = analyze(<<~RUBY)
          n = ARGV.first&.to_i || 0
          if n > 0
            "positive"
          else
            "non-positive"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable always-truthy-condition`" do
        result = analyze(<<~RUBY)
          x = 1
          if x # rigor:disable always-truthy-condition
            "yes"
          else
            "no"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      # Regression: the class-ivar pre-pass seeds every InstanceVariableWriteNode rvalue into a per-class accumulator.
      # Defensive-init idioms (`@x = v unless @x` / `@x = v if @x.nil?` / `unless defined?(@x); @x = v; end`) used to
      # seed `@x` as `Constant[v]`, then the predicate `@x` folded to that same constant and fired this rule against
      # working programs — most visibly in tdiary-core's `TDiary::Configuration#configure_attrs` (≈ 20 false positives
      # across a single block of consecutive defaults). The pre-pass now unions `Constant[nil]` into the seeded type for
      # writes that sit in the THEN body of a conditional whose predicate tests the same ivar's truthiness / nil-ness /
      # definedness.
      context "with defensive ivar-init idioms (tdiary-core configuration.rb cluster)" do
        it "does not fire on `@x = v unless @x`" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                @lang = "ja" unless @lang
                @style = "tDiary" unless @style
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on `@x = v if @x.nil?`" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                @lang = "ja" if @lang.nil?
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on `unless defined?(@x); @x = v; end`" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                @hide_form = false unless defined?(@hide_form)
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on `unless @x` block body that initialises @x" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                unless @lang
                  @lang = "ja"
                end
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        # Polarity check: the ELSE branch of `if @x; ...; else; @x = init; end` is also a defensive-init shape, but
        # treating its write as "guarded by nil" forces the read of `@x` elsewhere in the class to fold to
        # `union(init_type, nil)` and surfaces a possible-nil-receiver FP on any later call against `@x` that relies on
        # a method-call invariant (the tdiary `TDiary::TDiaryBase#do_eval_rhtml` shape). The fix leaves the ELSE branch
        # unguarded so those reads continue to type as they did before.
        it "does not over-mark the else branch of `if @x; ...; else; @x = init; end`" do
          result = analyze(<<~RUBY)
            class Foo
              def load_plugin
                if @plugin
                  @plugin
                else
                  @plugin = Object.new
                end
              end

              def use
                load_plugin
                @plugin.inspect
              end
            end
          RUBY
          nil_receiver_diags = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
          expect(nil_receiver_diags).to be_empty
        end
      end

      # ADR-58 WD1 — declaration-sourced ivar optionality (the ctor `@x = nil` seed unioned in via the class-ivar index)
      # is not diagnostic fuel for `possible-nil-receiver`. The 109-FP class on idiomatic data-structure Ruby: a node
      # field read whose nil arrives only from a sibling-method ctor seed, guarded by an unprovable cross-method
      # invariant. Flow-live nil (a method-local write or a failed-guard narrowing) keeps firing exactly as before.
      context "when the ivar nil is declaration-sourced (ADR-58 WD1)" do
        def nil_receiver_diags(result)
          result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        end

        it "does not fire on a local copy of a declaration-sourced ivar read (r = @right; r.key)" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :right, :key
              def initialize; @right = nil; @key = nil; end
              def link; @right = P.new; end
              def rotate
                r = @right
                r.key
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "does not fire on a declaration-sourced ivar read assigned to a local then chained" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :nxt, :value
              def initialize; @nxt = nil; @value = nil; end
              def link; @nxt = P.new; @value = P.new; end
              def head
                current = @nxt
                current.value
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "STILL fires on flow-live nil after a method-local write drops the mark" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :right, :key
              def initialize; @right = nil; end
              def link; @right = P.new; end
              def live(cond)
                r = @right
                r = nil if cond
                r.key
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).not_to be_empty
        end

        it "STILL fires on a method-local nil-bearing union assigned to a local" do
          result = analyze(<<~RUBY)
            def m(flag)
              x = if flag then "s" else nil end
              x.upcase
            end
          RUBY
          expect(nil_receiver_diags(result)).not_to be_empty
        end

        it "leaves a guarded traversal loop clean (unchanged)" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :nxt
              def initialize; @nxt = nil; end
              def link; @nxt = P.new; end
              def walk
                current = @nxt
                current = current.nxt until current.nil?
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end
      end

      # Flow-folding gap G1 — closed via the `Rigor::Inference::MutationWidening` hook in `eval_call`. The pre-fix shape
      # used to fold `arms.size == 1` to `Constant[true]` because the body's `arms << x` mutation was not reflected in
      # the post-loop binding. Mirrors the parse_union FP at lib/rigor/inference/hkt_body_parser.rb:140 documented in
      # CURRENT_WORK.md § Flow-folding.
      context "when a loop body mutates the seeded collection (G1, Mastodon cluster 4)" do
        it "does NOT fire on a tuple seeded then mutated inside a `while`" do
          result = analyze(<<~RUBY)
            def parse_union(tokens)
              arms = [tokens.first]
              while tokens.size > 1
                tokens.shift
                arms << tokens.first
              end
              return arms.first if arms.size == 1

              arms
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does NOT fire on a tuple mutated by `push` inside a `while`" do
          result = analyze(<<~RUBY)
            def collect(n)
              buf = [n]
              i = 0
              while i < n
                buf.push(i)
                i += 1
              end
              puts "single" if buf.size == 1

              buf
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does NOT fire on an instance-variable Tuple mutated by `<<` (G2 row)" do
          result = analyze(<<~RUBY)
            class Bag
              def initialize
                @tags = []
              end

              def absorb(items)
                items.each { |i| @tags << i }
                return if @tags.empty?

                @tags
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does NOT fire on an outer-scope tuple mutated INSIDE an `each {}` block" do
          # This is the hkt_registry.rb:212 shape: a local seeded as a tuple literal, mutated only inside an iterator
          # block, then probed with `.empty?` after the block. The block lives in a child scope; the propagation in
          # `MutationWidening.widen_after_block` carries the widening back to the outer scope.
          result = analyze(<<~RUBY)
            def collect_things(items)
              registrations = []
              items.each do |item|
                registrations << item
              end
              return :nothing if registrations.empty?

              registrations
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "still fires on a tuple that is genuinely never mutated" do
          # The widening only triggers on an in-place mutator call; a tuple whose size is a fact at the predicate site
          # MUST still fold. This pins the precision floor.
          result = analyze(<<~RUBY)
            arr = [1]
            puts "single" if arr.size == 1
          RUBY
          expect(truthy_diags(result)).not_to be_empty
        end
      end
    end

    # `flow.shadowed-rescue-clause` — a later rescue arm dead under an earlier superclass arm.
    describe "shadowed-rescue-clause rule" do
      def shadow_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.shadowed-rescue-clause" }
      end

      it "flags a narrower rescue after `rescue StandardError`" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue StandardError => e
            e
          rescue ArgumentError => e
            e
          end
        RUBY
        diag = shadow_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("rescue ArgumentError")
        expect(diag.message).to include("rescue StandardError")
        expect(shadow_diags(result).size).to eq(1)
      end

      it "flags a rescue after a bare `rescue` (implicit StandardError)" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue => e
            e
          rescue ArgumentError => e
            e
          end
        RUBY
        diag = shadow_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("rescue ArgumentError")
      end

      it "flags an exact duplicate exception class" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue ArgumentError
            1
          rescue ArgumentError
            2
          end
        RUBY
        expect(shadow_diags(result).size).to eq(1)
      end

      it "flags a multi-class arm whose every class is covered" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue StandardError
            1
          rescue ArgumentError, TypeError
            2
          end
        RUBY
        diag = shadow_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("rescue ArgumentError, TypeError")
      end

      it "flags a project-defined exception subclass after its rescued superclass" do
        result = analyze(<<~RUBY)
          class CustomError < StandardError
          end

          begin
            work
          rescue StandardError
            1
          rescue CustomError
            2
          end
        RUBY
        diag = shadow_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("rescue CustomError")
      end

      it "does not fire on the normal narrow-to-wide order" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue ArgumentError
            1
          rescue StandardError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not fire on a multi-class arm only partially covered" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue ArgumentError
            1
          rescue ArgumentError, IOError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not fire when the earlier clause names an unresolved constant" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue TotallyUnknownError
            1
          rescue ArgumentError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not fire when the later clause names an unresolved constant" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue StandardError
            1
          rescue TotallyUnknownError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not fire when a clause names a module (custom `===` semantics)" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue Kernel
            1
          rescue ArgumentError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not fire around a splat clause" do
        result = analyze(<<~RUBY)
          ERRORS = [StandardError].freeze
          begin
            work
          rescue *ERRORS
            1
          rescue ArgumentError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not fire around a dynamic exception expression" do
        result = analyze(<<~RUBY)
          klass = StandardError
          begin
            work
          rescue klass
            1
          rescue ArgumentError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not fire on unrelated sibling classes" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue ArgumentError
            1
          rescue TypeError
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "does not compare clauses across nested begin nodes" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue StandardError
            begin
              other
            rescue ArgumentError
              1
            end
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable shadowed-rescue-clause`" do
        result = analyze(<<~RUBY)
          begin
            work
          rescue StandardError
            1
          rescue ArgumentError # rigor:disable shadowed-rescue-clause
            2
          end
        RUBY
        expect(shadow_diags(result)).to be_empty
      end
    end

    # ADR-47 — narrowing-driven `case`/`when` clause reachability (WD1).
    describe "unreachable-clause rule (ADR-47)" do
      def clause_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.unreachable-clause" }
      end

      it "flags a `when` clause disjoint from the narrowed subject" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when String
            "s"
          when Integer
            "i"
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("when String")
        expect(clause_diags(result).size).to eq(1) # only the disjoint clause
      end

      it "does not fire on a reachable clause (subject not disjoint)" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          when String
            "s"
          end
        RUBY
        # x is Integer | String — both clauses are reachable.
        expect(clause_diags(result)).to be_empty
      end

      it "fires on a clause made dead by an earlier clause (prior-exhaustion)" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when Integer
            "i"
          when Float
            "f"
          end
        RUBY
        # x is Integer here, so `when Float` after `when Integer` is dead.
        expect(clause_diags(result).map(&:message)).to all(include("when Float"))
        expect(clause_diags(result).size).to eq(1)
      end

      it "never fires on a `Dynamic` subject (the gradual guarantee)" do
        result = analyze(<<~RUBY)
          def f(x)
            case x
            when String then 1
            when Integer then 2
            end
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "does not fire on non-constant clauses (`when nil` / ranges are out of WD1 scope)" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when nil
            "z"
          when 100..200
            "r"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "skips clauses inside a loop/block (incomplete mutation tracking)" do
        result = analyze(<<~RUBY)
          [1, 2].each do |x|
            case x
            when String
              "s"
            when Integer
              "i"
            end
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable unreachable-clause`" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when String
            "s" # rigor:disable unreachable-clause
          when Integer
            "i"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      # --- WD2: message precision + dead trailing else ---

      it "WD2: words a per-clause-disjoint dead clause as `disjoint`" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Float
            "f"
          when Integer
            "i"
          when String
            "s"
          end
        RUBY
        # x is Integer|String; `when Float` is disjoint, both later clauses live.
        diag = clause_diags(result).first
        expect(diag.message).to include("when Float")
        expect(diag.message).to include("disjoint")
        expect(clause_diags(result).size).to eq(1)
      end

      it "WD2: words a prior-exhausted dead clause as `already covered`" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when Integer
            "i"
          when Float
            "f"
          end
        RUBY
        # x is Integer; `when Float` is dead because `when Integer` exhausted it.
        diag = clause_diags(result).first
        expect(diag.message).to include("when Float")
        expect(diag.message).to include("already covered by an earlier")
        expect(diag.message).not_to include("disjoint")
      end

      it "WD2: flags a dead trailing `else` when the whens exhaust the subject" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          when String
            "s"
          else
            "never"
          end
        RUBY
        diag = clause_diags(result).find { |d| d.message.include?("else") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("unreachable `else'")
      end

      it "WD2: does NOT flag a defensive `else raise` (deliberate guard)" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          when String
            "s"
          else
            raise "unexpected type"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "WD2: does not flag a live `else` (subject not exhausted)" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          else
            "fallthrough"
          end
        RUBY
        # only String reaches the else — it is live.
        expect(clause_diags(result)).to be_empty
      end

      # --- WD3a: case/in bare class patterns ---

      it "WD3a: flags a `in C` clause disjoint from the narrowed subject" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in String
            "s"
          in Integer
            "i"
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("in String")
        expect(diag.message).to include("disjoint")
        expect(clause_diags(result).size).to eq(1)
      end

      it "WD3a: words a prior-exhausted `in` clause as `already covered`" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in Integer
            "i"
          in Float
            "f"
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag.message).to include("in Float")
        expect(diag.message).to include("already covered by an earlier `in'")
      end

      it "WD3a: handles `in C => y` capture of a bare class" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in String => s
            s
          in Integer => i
            i
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("in String")
      end

      it "WD3a: does NOT fire on non-class patterns (array/hash/value out of WD3a scope)" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in [a, b]
            a
          in {k:}
            k
          in 0
            "zero"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "WD3a: a prior-exhausting `in C` kills ANY later clause, even non-class" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in Integer
            "i"
          in [a, b]
            a
          end
        RUBY
        diag = clause_diags(result).find { |d| d.message.include?("[a, b]") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("already covered")
      end

      it "WD3a: never fires on a `Dynamic` subject (gradual guarantee)" do
        result = analyze(<<~RUBY)
          def f(x)
            case x
            in String then 1
            in Integer then 2
            end
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "WD3a: flags a dead `else` once the `in` clauses exhaust the subject" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          in Integer
            "i"
          in String
            "s"
          else
            "never"
          end
        RUBY
        diag = clause_diags(result).find { |d| d.message.include?("else") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("`in' clauses")
      end
    end

    describe "Hash key-presence narrowing (ADR-47 §4-3)" do
      def dump_messages(result)
        result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
      end

      # `h[:foo]` on an optional key reads `Integer?`; inside a `h.key?(:foo)` guard the optionality nil is gone →
      # `Integer`.
      it "narrows h[:foo] from Integer? to Integer after a `h.key?(:foo)` guard" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Config
            def lookup(h)
              a = h[:foo]
              Rigor.dump_type(a)
              if h.key?(:foo)
                b = h[:foo]
                Rigor.dump_type(b)
              end
            end
          end
        RUBY
          class Config
            def lookup: ({ ?foo: Integer }) -> void
          end
        RBS
        dumps = dump_messages(result)
        expect(dumps.first).to include("Integer?")          # unguarded: optionality nil present
        expect(dumps.last).to eq("dump_type: Integer")      # guarded: nil removed
      end

      # §4-3 false edge: `unless h.key?(:foo)` proves `:foo` absent, so `h[:foo]` reads `nil` (the key is dropped from
      # the shape).
      it "narrows h[:foo] to nil in the falsey edge (key proven absent)" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Config
            def lookup(h)
              unless h.key?(:foo)
                c = h[:foo]
                Rigor.dump_type(c)
              end
            end
          end
        RUBY
          class Config
            def lookup: ({ ?foo: Integer }) -> void
          end
        RBS
        expect(dump_messages(result).first).to eq("dump_type: nil")
      end
    end

    describe "Array non-empty narrowing (ADR-47 §4-4)" do
      def dump_messages(result)
        result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
      end

      # Inside an `unless arr.empty?` / `if arr.any?` guard the array is `non-empty-array[T]`, so
      # `size`/`length`/`count` refine from `non-negative-int` to `positive-int` (Elixir `tuple_size`-style).
      it "refines arr.size to positive-int inside a non-empty guard" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Box
            def head(arr)
              Rigor.dump_type(arr.size)
              unless arr.empty?
                Rigor.dump_type(arr)
                Rigor.dump_type(arr.size)
              end
            end
          end
        RUBY
          class Box
            def head: (Array[Integer]) -> void
          end
        RBS
        dumps = dump_messages(result)
        expect(dumps).to include("dump_type: non-negative-int") # unguarded
        expect(dumps).to include("dump_type: non-empty-array[Integer]") # narrowed receiver
        expect(dumps).to include("dump_type: positive-int") # guarded size
      end

      it "narrows on the true edge of `arr.any?`" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Box
            def head(arr)
              Rigor.dump_type(arr.size) if arr.any?
            end
          end
        RUBY
          class Box
            def head: (Array[Integer]) -> void
          end
        RBS
        expect(dump_messages(result)).to include("dump_type: positive-int")
      end
    end

    describe "method-visibility-mismatch rule (v0.1.2)" do
      def visibility_mismatch_diags(result)
        result.diagnostics.select { |d| d.rule == "def.method-visibility-mismatch" }
      end

      it "flags an explicit-receiver call to a method declared under `private`" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              secret
            end

            private

            def secret
              42
            end
          end

          Foo.new.secret
        RUBY
        diag = visibility_mismatch_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("private method")
        expect(diag.message).to include("`secret'")
        expect(diag.message).to include("Foo")
      end

      it "honours the `private :foo, :bar` named-argument form" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              42
            end

            def baz
              43
            end

            private :baz
          end

          Foo.new.baz
        RUBY
        expect(visibility_mismatch_diags(result).size).to eq(1)
      end

      it "does not flag implicit-self calls (always allowed for private)" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              secret
            end

            private

            def secret
              42
            end
          end
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "does not flag `self.foo` (Ruby 2.7+ permits self.private_method)" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              self.secret
            end

            private

            def secret
              42
            end
          end
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "does not flag a public method call on the same class" do
        result = analyze(<<~RUBY)
          class Foo
            def hello
              "hi"
            end
          end

          Foo.new.hello
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "switches default visibility back when `public` modifier follows" do
        result = analyze(<<~RUBY)
          class Foo
            private

            def secret
              42
            end

            public

            def open
              43
            end
          end

          Foo.new.open
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable method-visibility-mismatch`" do
        result = analyze(<<~RUBY)
          class Foo
            private

            def secret
              42
            end
          end

          Foo.new.secret # rigor:disable method-visibility-mismatch
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end
    end

    # ADR-35 slice 1 — Liskov signature rule for visibility.
    describe "override-visibility-reduced rule (ADR-35 slice 1)" do
      def override_visibility_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-visibility-reduced" }
      end

      it "flags a subclass override that makes a public method private" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def greet
              "hello"
            end
          end
        RUBY
        diag = override_visibility_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`greet'")
        expect(diag.message).to include("private")
        expect(diag.message).to include("Base")
      end

      it "flags a reduction from an included module's public method" do
        result = analyze(<<~RUBY)
          module Greeter
            def greet
              "hi"
            end
          end

          class Host
            include Greeter

            private

            def greet
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result).size).to eq(1)
      end

      it "flags a protected -> private reduction" do
        result = analyze(<<~RUBY)
          class Base
            protected

            def helper
              1
            end
          end

          class Sub < Base
            private

            def helper
              2
            end
          end
        RUBY
        expect(override_visibility_diags(result).size).to eq(1)
      end

      it "does not flag an override that preserves visibility" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            def greet
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "does not flag widening (private parent -> public override)" do
        result = analyze(<<~RUBY)
          class Base
            private

            def helper
              1
            end
          end

          class Sub < Base
            def helper
              2
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "does not flag a method that overrides nothing" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def fresh
              "new"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "resolves the ancestor cross-file" do
        result = analyze(files: {
                           "base.rb" => <<~RUBY,
                             class Base
                               def greet
                                 "hi"
                               end
                             end
                           RUBY
                           "sub.rb" => <<~RUBY
                             class Sub < Base
                               private

                               def greet
                                 "hello"
                               end
                             end
                           RUBY
                         })
        expect(override_visibility_diags(result).size).to eq(1)
      end

      it "is suppressed under the lenient profile" do
        result = analyze(<<~RUBY, config: { "severity_profile" => "lenient" })
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def greet
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable def.override-visibility-reduced`" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def greet # rigor:disable def.override-visibility-reduced
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end
    end

    # ADR-35 slice 2 — Liskov signature rule for returns (covariance).
    describe "override-return-widened rule (ADR-35 slice 2)" do
      def override_return_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-return-widened" }
      end

      let(:widen_sig) do
        { "demo.rbs" => <<~RBS }
          class Base
            def value: () -> Integer
          end

          class Sub < Base
            def value: () -> Object
          end
        RBS
      end

      it "flags an override that widens the inherited return type" do
        result = analyze(<<~RUBY, sig: widen_sig)
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
        diag = override_return_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`value'")
        expect(diag.message).to include("Base")
      end

      it "does not flag an override that narrows the return (covariant-safe)" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              1
            end
          end
        RUBY
          class Base
            def value: () -> Numeric
          end

          class Sub < Base
            def value: () -> Integer
          end
        RBS
        expect(override_return_diags(result)).to be_empty
      end

      it "flags a widening of a return inherited from an included module" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          module Producer
            def value
              1
            end
          end

          class Host
            include Producer

            def value
              Object.new
            end
          end
        RUBY
          module Producer
            def value: () -> Integer
          end

          class Host
            include Producer

            def value: () -> Object
          end
        RBS
        expect(override_return_diags(result).size).to eq(1)
      end

      it "does not fire when the override has no authored signature" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
          class Base
            def value: () -> Integer
          end
        RBS
        expect(override_return_diags(result)).to be_empty
      end

      it "does not fire when the parent return is untyped" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
          class Base
            def value: () -> untyped
          end

          class Sub < Base
            def value: () -> Object
          end
        RBS
        expect(override_return_diags(result)).to be_empty
      end

      it "is suppressed under the lenient profile" do
        result = analyze(<<~RUBY, sig: widen_sig, config: { "severity_profile" => "lenient" })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
        expect(override_return_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable def.override-return-widened`" do
        result = analyze(<<~RUBY, sig: widen_sig)
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value # rigor:disable def.override-return-widened
              Object.new
            end
          end
        RUBY
        expect(override_return_diags(result)).to be_empty
      end
    end

    # ADR-35 WD9 tier 1 — generic-instantiation-aware comparison. When the overriding subclass binds a
    # generic ancestor's type parameters (RBS `class Sub < Parent[Concrete]`), the parent signature is
    # compared at the *instantiated* type instead of degrading its type variable to `Dynamic[Top]`. An
    # unbound / propagated type variable keeps degrading to `Dynamic[Top]` and stays silent (FP-safe).
    describe "override rules — generic-instantiation-aware comparison (ADR-35 WD9 tier 1)" do
      def override_return_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-return-widened" }
      end

      def override_param_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-param-narrowed" }
      end

      it "flags a return widened relative to the instantiated generic parent contract" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Container
            def fetch
              1
            end
          end

          class IntContainer < Container
            def fetch
              Object.new
            end
          end
        RUBY
          class Container[T]
            def fetch: () -> T
          end

          class IntContainer < Container[Integer]
            def fetch: () -> Object
          end
        RBS
        # Parent `-> T` instantiated at `T = Integer` is `-> Integer`; the override widens to `-> Object`.
        # Before WD9 the bare `T` degraded to `Dynamic[Top]` and this stayed silent.
        diag = override_return_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`fetch'")
        expect(diag.message).to include("Container")
      end

      it "stays silent when the subclass propagates (does not bind) the ancestor type variable" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Container
            def fetch
              1
            end
          end

          class OpenContainer < Container
            def fetch
              Object.new
            end
          end
        RUBY
          class Container[T]
            def fetch: () -> T
          end

          class OpenContainer[T] < Container[T]
            def fetch: () -> Object
          end
        RBS
        # The subclass forwards its own unbound `T` to the ancestor, so the parent return degrades to
        # `Dynamic[Top]`, which accepts everything. This is the load-bearing FP-safety case.
        expect(override_return_diags(result)).to be_empty
      end

      it "does not fire when the override narrows relative to the instantiated parent (covariant-safe)" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Container
            def fetch
              1
            end
          end

          class NumContainer < Container
            def fetch
              1
            end
          end
        RUBY
          class Container[T]
            def fetch: () -> T
          end

          class NumContainer < Container[Numeric]
            def fetch: () -> Integer
          end
        RBS
        # Parent instantiated at `Numeric`; override returns the narrower `Integer` — allowed.
        expect(override_return_diags(result)).to be_empty
      end

      it "flags a parameter narrowed relative to the instantiated generic parent contract" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Sink
            def accept(value)
              value
            end
          end

          class NumSink < Sink
            def accept(value)
              value
            end
          end
        RUBY
          class Sink[T]
            def accept: (T) -> void
          end

          class NumSink < Sink[Numeric]
            def accept: (Integer) -> void
          end
        RBS
        # Parent `(T)` instantiated at `Numeric` is `(Numeric)`; the override narrows to `(Integer)`,
        # which cannot accept the wider parent argument. Before WD9 the bare `T` degraded to
        # `Dynamic[Top]` and this stayed silent.
        diag = override_param_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`accept'")
      end

      it "stays silent on a narrowed parameter when the subclass propagates the type variable" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Sink
            def accept(value)
              value
            end
          end

          class OpenSink < Sink
            def accept(value)
              value
            end
          end
        RUBY
          class Sink[T]
            def accept: (T) -> void
          end

          class OpenSink[T] < Sink[T]
            def accept: (Integer) -> void
          end
        RBS
        # The unbound ancestor `T` degrades to `Dynamic[Top]`, which is skipped by the comparison.
        expect(override_param_diags(result)).to be_empty
      end
    end

    # ADR-35 slice 3 — Liskov signature rule for parameters (contravariance). Uses real (loadable) classes
    # Numeric/Integer so the nominal subtype check resolves to :no rather than the FP-safe :maybe it returns for
    # unloadable user-only class hierarchies.
    describe "override-param-narrowed rule (ADR-35 slice 3)" do
      def override_param_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-param-narrowed" }
      end

      let(:base_sub_source) do
        <<~RUBY
          class Base
            def consume(value)
            end
          end

          class Sub < Base
            def consume(value)
            end
          end
        RUBY
      end

      let(:narrow_sig) do
        { "demo.rbs" => <<~RBS }
          class Base
            def consume: (Numeric) -> void
          end

          class Sub < Base
            def consume: (Integer) -> void
          end
        RBS
      end

      it "flags an override that narrows a parameter type" do
        result = analyze(base_sub_source, sig: narrow_sig)
        diag = override_param_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`consume'")
        expect(diag.message).to include("Base")
      end

      it "does not flag an override that widens a parameter (contravariant-safe)" do
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def consume: (Integer) -> void
          end

          class Sub < Base
            def consume: (Numeric) -> void
          end
        RBS
        expect(override_param_diags(result)).to be_empty
      end

      it "flags a parameter narrowing inherited from an included module" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          module Consumer
            def consume(value)
            end
          end

          class Host
            include Consumer

            def consume(value)
            end
          end
        RUBY
          module Consumer
            def consume: (Numeric) -> void
          end

          class Host
            include Consumer

            def consume: (Integer) -> void
          end
        RBS
        expect(override_param_diags(result).size).to eq(1)
      end

      it "does not fire when the parent parameter is untyped" do
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def consume: (untyped) -> void
          end

          class Sub < Base
            def consume: (Integer) -> void
          end
        RBS
        expect(override_param_diags(result)).to be_empty
      end

      it "does not fire when the override has no authored signature" do
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def consume: (Numeric) -> void
          end
        RBS
        expect(override_param_diags(result)).to be_empty
      end

      it "is suppressed under the lenient profile" do
        result = analyze(base_sub_source, sig: narrow_sig, config: { "severity_profile" => "lenient" })
        expect(override_param_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable def.override-param-narrowed`" do
        result = analyze(<<~RUBY, sig: narrow_sig)
          class Base
            def consume(value)
            end
          end

          class Sub < Base
            def consume(value) # rigor:disable def.override-param-narrowed
            end
          end
        RUBY
        expect(override_param_diags(result)).to be_empty
      end
    end

    describe "dead-assignment rule (v0.1.2)" do
      def dead_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.dead-assignment" }
      end

      it "flags a local that is assigned but never read" do
        result = analyze(<<~RUBY)
          def example
            x = 1
            42
          end
        RUBY
        diag = dead_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("local `x'")
        expect(diag.message).to include("`example'")
        expect(diag.message).to include("never read")
      end

      it "does not flag the trailing assignment (Ruby's implicit return)" do
        result = analyze(<<~RUBY)
          def example
            x = 1
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag locals that are read later in the same body" do
        result = analyze(<<~RUBY)
          def example
            x = 1
            x + 2
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag locals read inside a nested block" do
        result = analyze(<<~RUBY)
          def example
            x = [1, 2, 3]
            [4, 5].each { |y| puts y + x.size }
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag names starting with `_` (intentionally unused)" do
        result = analyze(<<~RUBY)
          def example
            _scratch = 1
            42
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag operator-writes (`x += 1`)" do
        result = analyze(<<~RUBY)
          def example
            x = 0
            x += 1
            42
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag multi-assignment (`a, b = foo`)" do
        result = analyze(<<~RUBY)
          def example
            a, b = [1, 2]
            b
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag top-level assignments (the rule scope is method bodies)" do
        result = analyze(<<~RUBY)
          dead_at_top = 1
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable dead-assignment`" do
        result = analyze(<<~RUBY)
          def example
            x = 1 # rigor:disable dead-assignment
            42
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end
    end

    describe "duplicate-hash-key rule" do
      def dup_key_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.duplicate-hash-key" }
      end

      it "flags a duplicate symbol key, pointing at the later occurrence and naming the first line" do
        result = analyze(<<~RUBY)
          h = {
            a: 1,
            b: 2,
            a: 3
          }
          h
        RUBY
        diag = dup_key_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("duplicate hash key `:a'")
        expect(diag.message).to include("first set at line 2")
        expect(diag.line).to eq(4)
      end

      it "flags a duplicate plain-string key" do
        result = analyze(<<~RUBY)
          h = { "x" => 1, "x" => 2 }
          h
        RUBY
        diag = dup_key_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include(%(duplicate hash key `"x"'))
      end

      it "flags a duplicate integer key" do
        result = analyze(<<~RUBY)
          h = { 1 => :a, 2 => :b, 1 => :c }
          h
        RUBY
        expect(dup_key_diags(result).size).to eq(1)
      end

      it "flags the same symbol spelled as shorthand and hashrocket" do
        result = analyze(<<~RUBY)
          h = { a: 1, :a => 2 }
          h
        RUBY
        diag = dup_key_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("duplicate hash key `:a'")
      end

      it "flags duplicate bare keyword arguments in a call (KeywordHashNode)" do
        result = analyze(<<~RUBY)
          def m(**opts)
            opts
          end
          m(a: 1, a: 2)
        RUBY
        expect(dup_key_diags(result).size).to eq(1)
      end

      it "flags a literal pair straddling a `**splat` (the splat does not rescue the collision)" do
        result = analyze(<<~RUBY)
          extra = { b: 2 }
          h = { a: 1, **extra, a: 3 }
          h
        RUBY
        expect(dup_key_diags(result).size).to eq(1)
      end

      it "does not flag distinct keys" do
        result = analyze(<<~RUBY)
          h = { a: 1, b: 2, "a" => 3 }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "does not flag repeated interpolated-string keys (not value-pinned)" do
        result = analyze(<<~'RUBY')
          x = "k"
          h = { "a#{x}" => 1, "a#{x}" => 2 }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "does not cross-compare a symbol and a string with the same text" do
        result = analyze(<<~RUBY)
          h = { a: 1, "a" => 2 }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "flags Float spellings of the same value and labels with the repeat's raw source slice" do
        # `1.0` and `1.00` DO collide (`Float#eql?` on the same f64), and the label deliberately
        # renders the raw source slice of the REPEAT node — not a canonicalised `1.0` — so the
        # message points at the spelling the user actually wrote. Symbol/string keys canonicalise
        # instead; this split is contract (docs/notes/20260716-upstream-feedback.md item 5).
        result = analyze(<<~RUBY)
          h = { 1.0 => :a, 1.00 => :b }
          h
        RUBY
        diag = dup_key_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("duplicate hash key `1.00'")
      end

      it "does not cross-compare Integer and Float keys (1.eql?(1.0) is false)" do
        result = analyze(<<~RUBY)
          h = { 1 => :int, 1.0 => :float }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "does not flag repeated constant keys" do
        result = analyze(<<~RUBY)
          KEY = :a
          h = { KEY => 1, KEY => 2 }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "does not flag repeated method-call keys" do
        result = analyze(<<~RUBY)
          def key
            :a
          end
          h = { key => 1, key => 2 }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "does not flag a `**splat` alongside distinct literal keys" do
        result = analyze(<<~RUBY)
          extra = { c: 3 }
          h = { a: 1, **extra, b: 2 }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "scopes each Hash literal independently (nested literals do not collide with the outer one)" do
        result = analyze(<<~RUBY)
          h = { a: { a: 1 }, b: 2 }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable duplicate-hash-key`" do
        result = analyze(<<~RUBY)
          h = {
            a: 1,
            a: 2 # rigor:disable duplicate-hash-key
          }
          h
        RUBY
        expect(dup_key_diags(result)).to be_empty
      end
    end

    describe "return-in-ensure rule (v0.3.0)" do
      def ensure_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.return-in-ensure" }
      end

      it "flags a `return` in the ensure clause of a def body" do
        result = analyze(<<~RUBY)
          def example
            compute
          ensure
            return 1
          end
        RUBY
        diag = ensure_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("`return' inside `ensure'")
        expect(diag.message).to include("swallows")
        expect(diag.line).to eq(4)
      end

      it "flags a `return` in the ensure clause of a begin block" do
        result = analyze(<<~RUBY)
          def example
            begin
              compute
            ensure
              return 1
            end
          end
        RUBY
        expect(ensure_diags(result).size).to eq(1)
      end

      it "flags a `return` inside a plain block inside the ensure body" do
        result = analyze(<<~RUBY)
          def example
            compute
          ensure
            [1, 2].each do |i|
              return i
            end
          end
        RUBY
        expect(ensure_diags(result).size).to eq(1)
      end

      it "does not flag a `return` inside a nested def within the ensure body" do
        result = analyze(<<~RUBY)
          def example
            compute
          ensure
            def helper
              return 1
            end
          end
        RUBY
        expect(ensure_diags(result)).to be_empty
      end

      it "does not flag a `return` inside a lambda within the ensure body" do
        result = analyze(<<~RUBY)
          def example
            compute
          ensure
            arrow = -> { return 1 }
            keyword = lambda { return 2 }
            arrow.call + keyword.call
          end
        RUBY
        expect(ensure_diags(result)).to be_empty
      end

      it "does not flag a `return` inside a define_method block within the ensure body" do
        result = analyze(<<~RUBY)
          class Host
            def example
              compute
            ensure
              define_method(:regenerated) { return 2 } if $rebuild
            end
          end
        RUBY
        expect(ensure_diags(result)).to be_empty
      end

      it "does not flag an ensure clause without an explicit return" do
        result = analyze(<<~RUBY)
          def example
            compute
          ensure
            cleanup
          end
        RUBY
        expect(ensure_diags(result)).to be_empty
      end

      it "does not flag a `return` outside the ensure clause of the same begin" do
        result = analyze(<<~RUBY)
          def example
            return compute
          ensure
            cleanup
          end
        RUBY
        expect(ensure_diags(result)).to be_empty
      end

      it "collects a `return` in a nested begin/ensure inside an ensure body exactly once" do
        result = analyze(<<~RUBY)
          def example
            compute
          ensure
            begin
              cleanup
            ensure
              return 1
            end
          end
        RUBY
        expect(ensure_diags(result).size).to eq(1)
      end

      it "is suppressible via `# rigor:disable flow.return-in-ensure`" do
        result = analyze(<<~RUBY)
          def example
            compute
          ensure
            return 1 # rigor:disable flow.return-in-ensure
          end
        RUBY
        expect(ensure_diags(result)).to be_empty
      end
    end

    describe "ivar-write-mismatch rule (v0.1.2)" do
      def ivar_diags(result)
        result.diagnostics.select { |d| d.rule == "def.ivar-write-mismatch" }
      end

      it "flags a String → Integer ivar drift in the same class" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @name = "Alice"
            end

            def reset
              @name = 42
            end
          end
        RUBY
        diag = ivar_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("@name")
        expect(diag.message).to include("Foo")
        expect(diag.message).to include("String")
        expect(diag.message).to include("Integer")
      end

      it "does not flag widening to nil (intentional 'clear' idiom)" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @value = "hello"
            end

            def clear
              @value = nil
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag multiple writes that share the same concrete class" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @count = 0
            end

            def bump
              @count = 5
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag class-body ivars outside any def" do
        # Class-level ivars (`Module#@var`) are a separate surface the engine doesn't yet model.
        result = analyze(<<~RUBY)
          class Foo
            @config = "default"
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag ivars in unrelated classes that share a name" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @value = "hello"
            end
          end

          class Bar
            def initialize
              @value = 42
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag the bool flag idiom (false in initialize, true elsewhere)" do
        # Common idiom: a memoization flag starts at `false` and transitions to `true` once the underlying value has
        # been computed. Both writes are conceptually `bool` — the rule MUST NOT fire on this shape.
        result = analyze(<<~RUBY)
          class Holder
            def initialize
              @loaded = false
              @value = nil
            end

            def fetch
              return @value if @loaded

              @value = compute
              @loaded = true
              @value
            end

            def compute
              42
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag a nil-placeholder followed by concrete writes (nullable-slot idiom)" do
        # The `@parse_method = nil` placeholder followed by per-state `@parse_method = :foo` / `:bar` assignments is the
        # common nullable-slot idiom. Pre-fix the `NilClass` placeholder anchored as `first_class` and every concrete
        # write tripped the rule; the canonical type is now the first non-nil write so neither `Symbol → Symbol` (same
        # class) nor `nil → Symbol` widening fires.
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @parse_method = nil
            end

            def step(line)
              if line == "a"
                @parse_method = :parse_a
              elsif line == "b"
                @parse_method = :parse_b
              elsif line == "c"
                @parse_method = nil
              end
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "still flags Symbol → String drift even with a leading nil placeholder" do
        # The leading `nil` shouldn't mask a genuine drift between two distinct concrete classes.
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @value = nil
            end

            def first_write
              @value = :sym
            end

            def second_write
              @value = "string"
            end
          end
        RUBY
        diag = ivar_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("Symbol")
        expect(diag.message).to include("String")
      end

      it "still flags a genuine bool → String drift" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @flag = true
            end

            def reset
              @flag = "ready"
            end
          end
        RUBY
        diag = ivar_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("bool")
        expect(diag.message).to include("String")
      end

      # Issue #909 — the class object's ivars and an instance's are different stores, and both spellings of a
      # singleton def must say so.
      it "does not flag a `class << self` write that diverges from the instance facet" do
        result = analyze(<<~RUBY)
          class SingletonMix
            def initialize
              @state = "idle"
            end

            class << self
              def configure
                @state = 42
              end
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag the `def self.x` spelling of the same divergence" do
        result = analyze(<<~RUBY)
          class SingletonMix
            def initialize
              @state = "idle"
            end

            def self.configure
              @state = 42
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "still flags a genuine instance-side divergence inside a class that also opens `class << self`" do
        result = analyze(<<~RUBY)
          class SingletonMix
            def initialize
              @state = "idle"
            end

            def reset
              @state = 42
            end

            class << self
              def configure
                @state = :configured
              end
            end
          end
        RUBY
        expect(ivar_diags(result).size).to eq(1)
        expect(ivar_diags(result).first.message).to include("Integer")
      end

      # Issue #909 — `Class.new do … end` defines a class of its own; its ivars are not the enclosing
      # class's.
      it "does not flag a write inside an anonymous-class factory block" do
        result = analyze(<<~RUBY)
          class Outer
            def initialize
              @own = "outer"
            end

            Inner = Class.new do
              def initialize
                @own = 42
              end
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "still flags a divergence inside a plain (non-class-building) block" do
        result = analyze(<<~RUBY)
          class Outer
            def initialize
              @own = "outer"
            end

            def each_thing
              [1].each do |n|
                @own = n
              end
            end
          end
        RUBY
        expect(ivar_diags(result).size).to eq(1)
      end

      it "is suppressible via `# rigor:disable ivar-write-mismatch`" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @name = "Alice"
            end

            def reset
              @name = 42 # rigor:disable ivar-write-mismatch
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end
    end
  end
end
