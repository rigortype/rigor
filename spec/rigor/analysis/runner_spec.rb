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

  describe "exclude: patterns filter directory globs" do
    # Each test plants a parse-error-shaped file (unclosed `def`)
    # so analysis attempts surface as diagnostics; the test then
    # checks whether those diagnostics include the planted path.
    let(:bad_source) { "def broken\n" }

    it "skips the built-in vendor/bundle pattern when a directory expansion contains it" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src")
        vendored = File.join(src, "vendor", "bundle", "ruby", "4.0.0", "gems", "fakegem")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(src, "real.rb"), bad_source)
        File.write(File.join(vendored, "lib.rb"), bad_source)

        configuration = Rigor::Configuration.new("paths" => [src])
        result = described_class.new(configuration: configuration, cache_store: nil).run

        analysed = result.diagnostics.map(&:path)
        expect(analysed).to include(File.join(src, "real.rb"))
        expect(analysed).not_to include(File.join(vendored, "lib.rb"))
      end
    end

    it "honours user-supplied exclude patterns from `.rigor.yml`" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src")
        FileUtils.mkdir_p(File.join(src, "fixtures"))
        File.write(File.join(src, "real.rb"), bad_source)
        File.write(File.join(src, "fixtures", "demo.rb"), bad_source)

        configuration = Rigor::Configuration.new(
          "paths" => [src], "exclude" => ["**/fixtures/**"]
        )
        result = described_class.new(configuration: configuration, cache_store: nil).run

        analysed = result.diagnostics.map(&:path)
        expect(analysed).to include(File.join(src, "real.rb"))
        expect(analysed).not_to include(File.join(src, "fixtures", "demo.rb"))
      end
    end

    it "does NOT exclude explicit file arguments (only directory globs filter)" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "vendor", "bundle"))
        explicit = File.join(dir, "vendor", "bundle", "lib.rb")
        File.write(explicit, bad_source)

        configuration = Rigor::Configuration.new("paths" => [explicit])
        result = described_class.new(configuration: configuration, cache_store: nil).run

        expect(result.diagnostics.map(&:path)).to include(explicit)
      end
    end
  end

  describe "configuration wiring at runtime (audit guard)" do
    # Adjacent to the `target_ruby` block below, these specs guard
    # against any of the documented `.rigor.yml` settings going
    # phantom — i.e., loaded into `Configuration` but never read
    # at runtime. The `cache.path` regression that prompted this
    # block (the CLI hardcoded `".rigor/cache"` and ignored the
    # config) is covered separately in `cli_spec.rb`.

    it "loads `libraries:` stdlib RBS into Environment.for_project" do
      libraries_args = nil
      allow(Rigor::Environment).to receive(:for_project).and_wrap_original do |original, **kwargs|
        libraries_args = kwargs[:libraries]
        original.call(**kwargs)
      end
      analyze("x = 1\n", config: { "libraries" => %w[csv set] })

      expect(libraries_args).to include("csv")
      expect(libraries_args).to include("set")
    end

    it "passes `signature_paths:` to Environment.for_project" do
      sig_paths_args = nil
      allow(Rigor::Environment).to receive(:for_project).and_wrap_original do |original, **kwargs|
        sig_paths_args = kwargs[:signature_paths]
        original.call(**kwargs)
      end
      analyze("x = 1\n", config: { "signature_paths" => %w[custom-sig vendor/sig] })

      expect(sig_paths_args).to eq(%w[custom-sig vendor/sig])
    end

    it "loads custom RBS classes declared under signature_paths: at runtime" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "code.rb"), "x = 1\n")
        FileUtils.mkdir_p(File.join(dir, "custom-sig"))
        File.write(File.join(dir, "custom-sig", "marker.rbs"), "class CustomMarker\nend\n")

        configuration = Rigor::Configuration.new(
          "paths" => [File.join(dir, "code.rb")],
          "signature_paths" => [File.join(dir, "custom-sig")]
        )
        env = Rigor::Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )
        scope = Rigor::Scope.empty(environment: env)
        expect(scope.environment.nominal_for_name("CustomMarker")).not_to be_nil
      end
    end

    it "extends the plugin TrustPolicy's allowed_read_roots from `plugins_io.allowed_paths`" do
      captured_kwargs = nil
      allow(Rigor::Plugin::TrustPolicy).to receive(:new).and_wrap_original do |original, **kwargs|
        captured_kwargs ||= kwargs
        original.call(**kwargs)
      end
      analyze("x = 1\n", config: {
                "plugins" => ["rigor-fake"],
                "plugins_io" => { "network" => "disabled", "allowed_paths" => %w[vendor/generated] }
              })

      expect(captured_kwargs).not_to be_nil
      # The `analyze` helper chdirs into a tmpdir; on macOS the
      # tmpdir resolves under `/private/tmp/...`, so match by
      # suffix rather than full prefix to stay portable.
      expect(captured_kwargs[:allowed_read_roots]).to include(end_with("/vendor/generated"))
      expect(captured_kwargs[:network_policy]).to eq(:disabled)
    end
  end

  describe "target_ruby wiring (`.rigor.yml` -> Prism version:)" do
    it "passes target_ruby through to Prism so the configured version drives the parse" do
      # Prism's `version: "3.4"` accepts current Ruby syntax.
      result = analyze("x = 1\n", config: { "target_ruby" => "3.4" })
      expect(result.diagnostics.select { |d| d.message.include?("parse") }).to be_empty
    end

    it "surfaces a configuration-error diagnostic when target_ruby is not Prism-accepted" do
      # `3.0` matches the format regex but Prism rejects it. The
      # one-time smoke parse in `Runner#run` converts the
      # `ArgumentError` into a single `:builtin configuration-error`
      # diagnostic so the run fails fast rather than crashing.
      result = analyze("x = 1\n", config: { "target_ruby" => "3.0" })
      diag = result.diagnostics.find { |d| d.rule == "configuration-error" }
      expect(diag).not_to be_nil
      expect(diag.path).to eq(".rigor.yml")
      expect(diag.message).to include('"3.0"')
    end
  end

  describe "cache_store surface (v0.0.9 group A slice 1)" do
    let(:configuration) { Rigor::Configuration.new("paths" => []) }

    it "exposes a Cache::Store rooted at .rigor/cache by default" do
      runner = described_class.new(configuration: configuration)
      expect(runner.cache_store).to be_a(Rigor::Cache::Store)
      expect(runner.cache_store.root).to eq(Rigor::Analysis::Runner::DEFAULT_CACHE_ROOT)
    end

    it "accepts an explicit cache_store override" do
      Dir.mktmpdir do |dir|
        custom = Rigor::Cache::Store.new(root: File.join(dir, "alt-cache"))
        runner = described_class.new(configuration: configuration, cache_store: custom)
        expect(runner.cache_store).to equal(custom)
      end
    end

    it "honours a nil cache_store (caching disabled, e.g. --no-cache)" do
      runner = described_class.new(configuration: configuration, cache_store: nil)
      expect(runner.cache_store).to be_nil
    end
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
      end

      # ADR-8 § "`def.return-type-mismatch` rule"
      describe "def.return-type-mismatch rule" do # rubocop:disable RSpec/NestedGroups
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
      end

      # ADR-8 § "Severity profile"
      describe "severity profile re-stamping (v0.1.0+)" do # rubocop:disable RSpec/NestedGroups
        it "lenient profile drops call.argument-type-mismatch to :warning" do # rubocop:disable RSpec/ExampleLength
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
              result = described_class.new(configuration: configuration, cache_store: nil).run
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
              result = described_class.new(configuration: configuration, cache_store: nil).run
              expect(result.diagnostics.find { |d| d.rule == "call.undefined-method" }).to be_nil
            end
          end
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
        # `class_object.name.nil?` folds to `Constant<false>`
        # because RBS declares `Module#name -> String`, but
        # anonymous classes really do return nil at runtime.
        # The literal-only envelope avoids flagging the
        # defensive `raise ... if x.name.nil?` shape.
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
        # The diagnostic points at the dead branch's location,
        # so the suppression comment lives on the dead-branch
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

    describe "method-visibility-mismatch rule (v0.1.2)" do
      def visibility_mismatch_diags(result)
        result.diagnostics.select { |d| d.rule == "def.method-visibility-mismatch" }
      end

      it "flags an explicit-receiver call to a method declared under `private`" do # rubocop:disable RSpec/ExampleLength
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
  end

  describe "implicit-self call dispatch (v0.0.3 A)" do
    it "prefers a top-level `def` over RBS dispatch for implicit-self calls" do
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def helper(value)
          value
        end
        x = helper(42)
        assert_type("42", x)
      RUBY

      expect(result.diagnostics.select { |d| d.rule == "assert.type-mismatch" }).to be_empty
    end

    it "returns Dynamic[Top] when the top-level def has a complex param shape" do
      # `def helper(x, kind: :default)` has a kwarg — the
      # first-iteration binder rejects it. The engine still
      # prefers the local def over RBS dispatch and returns
      # `Dynamic[Top]`, suppressing the spurious
      # `Array#select`-style mis-routing that previously
      # caused `select(...)` to type as `Array[Elem]`.
      result = analyze(<<~RUBY)
        def select(class_name, method_name, kind: :instance)
          class_name
        end
        mt = select("Array", :first)
        mt.no_such_method_on_array
      RUBY

      # `mt` is `Dynamic[Top]`; the undefined-method rule
      # skips Dynamic receivers so no diagnostic surfaces.
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end
  end

  describe "RSpec matcher narrowing (v0.0.3 B)" do
    it "narrows away from nil after `expect(x).not_to be_nil`" do
      result = analyze(<<~RUBY)
        x = if rand < 0.5
          "hello"
        else
          nil
        end
        expect(x).not_to be_nil
        x.upcase
      RUBY

      nil_errors = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
      expect(nil_errors).to be_empty
    end

    it "also recognises `to_not be_nil` (alias)" do
      result = analyze(<<~RUBY)
        x = if rand < 0.5
          "hello"
        else
          nil
        end
        expect(x).to_not be_nil
        x.upcase
      RUBY

      expect(result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }).to be_empty
    end

    it "narrows a union to the asserted class after `expect(x).to be_a(C)`" do
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        x = if rand < 0.5
          "hello"
        else
          42
        end
        expect(x).to be_a(Integer)
        assert_type("42", x)
      RUBY

      # `String | 42` narrowed to `Integer` keeps only the
      # integer-side carrier (Constant[42] survives because
      # it is a subtype of Integer); the String carrier is
      # dropped.
      mismatch = result.diagnostics.find { |d| d.rule == "assert.type-mismatch" }
      expect(mismatch).to be_nil
    end

    it "leaves the scope unchanged when the matcher shape is unrecognised" do
      # `to be_truthy` is intentionally NOT modelled; the
      # post-call type of `x` should remain `String | nil`
      # and `x.upcase` should still flag.
      result = analyze(<<~RUBY)
        x = if rand < 0.5
          "hello"
        else
          nil
        end
        expect(x).to be_truthy
        x.upcase
      RUBY

      nil_errors = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
      expect(nil_errors).not_to be_empty
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

  describe "always-raises rule (Integer division/modulo by zero)" do
    it "flags `5 / 0` as always-raising at :error severity" do
      result = analyze("5 / 0\n")
      diag = result.diagnostics.find { |d| d.rule == "flow.always-raises" }
      expect(diag).not_to be_nil
      expect(diag.message).to include("ZeroDivisionError")
      expect(diag.severity).to eq(:error)
    end

    it "flags every recognised raising operator on Integer" do
      sources = {
        "5 / 0\n" => "/",
        "5 % 0\n" => "%",
        "5.div(0)\n" => "div",
        "5.modulo(0)\n" => "modulo",
        "5.divmod(0)\n" => "divmod"
      }
      sources.each do |src, label|
        diag = analyze(src).diagnostics.find { |d| d.rule == "flow.always-raises" }
        expect(diag).not_to(be_nil, "expected an always-raises diagnostic for `#{label}`")
      end
    end

    it "fires when the receiver is Nominal[Integer] (wider receiver)" do
      diag = analyze("rand(100) / 0\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      expect(diag).not_to be_nil
    end

    it "does not fire on Float arithmetic (returns Infinity, not raise)" do
      expect(
        analyze("5.0 / 0\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
      expect(
        analyze("5 / 0.0\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
    end

    it "does not fire on Integer#fdiv (returns Infinity, not raise)" do
      expect(
        analyze("5.fdiv(0)\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
    end

    it "does not fire when the divisor is non-zero" do
      expect(analyze("5 / 2\n")).to be_success
    end

    it "does not fire when the divisor cannot be proved zero" do
      # `rand(100)` could be zero but the analyzer cannot
      # prove it, so the rule stays silent.
      expect(
        analyze("rand(100) / rand(100)\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
    end

    it "is suppressible via `# rigor:disable always-raises`" do
      result = analyze("5 / 0 # rigor:disable always-raises\n")
      expect(result.diagnostics.find { |d| d.rule == "flow.always-raises" }).to be_nil
    end
  end

  describe "plugin diagnostic emission (v0.1.0 slice 5-A/5-B)" do
    let(:plugin_class) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "demo-emitter", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          [
            Rigor::Analysis::Diagnostic.new(
              path: path, line: 1, column: 1,
              message: "demo plugin says hello",
              severity: :warning,
              rule: "saw-file"
            )
          ]
        end
      end
      stub_const("FakeDemoEmitterPlugin", klass)
      klass
    end

    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    def run_with_plugin(plugin_class:, source: "x = 1\n")
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-demo-emitter"]
          )
        )
        requirer = lambda { |_name|
          Rigor::Plugin.register(plugin_class)
          true
        }
        described_class.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: requirer
        ).run
      end
    end

    it "auto-stamps plugin-emitted diagnostics with source_family plugin.<id>" do
      result = run_with_plugin(plugin_class: plugin_class)
      diag = result.diagnostics.find { |d| d.rule == "saw-file" }
      expect(diag).not_to be_nil
      expect(diag.source_family).to eq("plugin.demo-emitter")
      expect(diag.qualified_rule).to eq("plugin.demo-emitter.saw-file")
      expect(diag.to_s).to include("[plugin.demo-emitter.saw-file]")
    end

    it "isolates plugin exceptions as :plugin_loader runtime-error diagnostics" do
      bomb_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "bomb-emitter", version: "0.1.0")
      end
      bomb_class.define_method(:diagnostics_for_file) { |**| raise "kaboom" }
      stub_const("FakeBombEmitterPlugin", bomb_class)

      result = run_with_plugin(plugin_class: bomb_class)
      diag = result.diagnostics.find { |d| d.source_family == :plugin_loader && d.rule == "runtime-error" }
      expect(diag).not_to be_nil
      expect(diag.message).to include("kaboom")
    end

    it "leaves the diagnostic stream unchanged when no plugin emits" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => [File.join(dir, "demo.rb")])
        )
        result = described_class.new(configuration: configuration, cache_store: nil).run
        expect(result.diagnostics.select { |d| d.source_family.to_s.start_with?("plugin.") }).to be_empty
      end
    end
  end

  describe "Plugin#flow_contribution_for return-type override (v0.1.1 / Track 2 slice 7)" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    def run_with(plugin_class, source: "x = 1\n")
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-flow-contributor"]
          )
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(plugin_class)
          true
        end
        runner = described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        )
        [runner, runner.run]
      end
    end

    it "threads the plugin registry through Environment#plugin_registry" do
      noop_plugin = Class.new(Rigor::Plugin::Base) do
        manifest(id: "flow-noop", version: "0.1.0")
      end
      stub_const("FakeFlowNoopPlugin", noop_plugin)

      runner, result = run_with(noop_plugin)
      expect(result).to be_a(Rigor::Analysis::Result)
      expect(runner.plugin_registry.ids).to eq(["flow-noop"])
    end

    it "isolates a #flow_contribution_for raise — dispatch keeps running, no plugin_loader runtime-error" do
      raising = Class.new(Rigor::Plugin::Base) do
        manifest(id: "raising-contributor", version: "0.1.0")

        def flow_contribution_for(call_node:, scope:) # rubocop:disable Lint/UnusedMethodArgument
          raise "boom"
        end
      end
      stub_const("FakeRaisingContributorPlugin", raising)

      _, result = run_with(raising, source: "[1, 2, 3].first\n")
      runtime_errors = result.diagnostics.select do |d|
        d.source_family == :plugin_loader && d.rule == "runtime-error"
      end
      # The contribution is silently dropped — no diagnostic. The
      # rest of the run continues. (Plugins that need to surface
      # their own errors should emit through diagnostics_for_file.)
      expect(runtime_errors).to be_empty
      expect(result).to be_a(Rigor::Analysis::Result)
    end
  end

  describe "Plugin#prepare invocation (v0.1.1 / ADR-9 slice 3)" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    def run_with_plugin(plugin_class)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-prepare-test"]
          )
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(plugin_class)
          true
        end
        described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        ).run
      end
    end

    let(:publishing_plugin) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "prepare-test", version: "0.1.0")

        def prepare(services)
          services.fact_store.publish(plugin_id: manifest.id, name: :greeting, value: "hello")
        end

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          greeting = services.fact_store.read(plugin_id: manifest.id, name: :greeting)
          [Rigor::Analysis::Diagnostic.new(
            path: path, line: 1, column: 1,
            message: "saw fact: #{greeting.inspect}", severity: :info, rule: "saw-fact"
          )]
        end
      end
      stub_const("FakePrepareTestPlugin", klass)
      klass
    end

    it "calls #prepare on every loaded plugin so facts are visible per-file" do
      result = run_with_plugin(publishing_plugin)
      diag = result.diagnostics.find { |d| d.rule == "saw-fact" }
      expect(diag).not_to be_nil
      expect(diag.message).to include('"hello"')
    end

    it "isolates a #prepare raise as a :plugin_loader runtime-error diagnostic" do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "prepare-bomb", version: "0.1.0")

        def prepare(_services)
          raise "kaboom"
        end
      end
      stub_const("FakePrepareBombPlugin", klass)

      result = run_with_plugin(klass)
      diag = result.diagnostics.find do |d|
        d.source_family == :plugin_loader && d.rule == "runtime-error" && d.message.include?("prepare")
      end
      expect(diag).not_to be_nil
      expect(diag.message).to include("kaboom")
    end
  end
end
