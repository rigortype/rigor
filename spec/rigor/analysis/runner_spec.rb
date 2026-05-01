# frozen_string_literal: true

require "tmpdir"
require "rigor/analysis/runner"

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
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "broken.rb")
      File.write(source_path, "def broken\n")

      configuration = Rigor::Configuration.new("paths" => [dir])
      result = described_class.new(configuration: configuration).run

      expect(result).not_to be_success
      expect(result.diagnostics.first.path).to eq(source_path)
      expect(result.diagnostics.first.message).not_to be_empty
    end
  end

  describe "CheckRules diagnostics (Slice 7 phase 8)" do
    it "flags an undefined method on a typed Constant receiver" do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, "demo.rb")
        File.write(source_path, "\"hello\".no_such_method\n")

        configuration = Rigor::Configuration.new("paths" => [dir])
        result = described_class.new(configuration: configuration).run

        diag = result.diagnostics.find { |d| d.message.include?("no_such_method") }
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:error)
        expect(diag.line).to eq(1)
      end
    end

    it "does not flag a method that exists on the receiver class" do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, "ok.rb")
        File.write(source_path, "[1, 2, 3].push(4)\n\"x\".upcase\n")

        configuration = Rigor::Configuration.new("paths" => [dir])
        result = described_class.new(configuration: configuration).run

        expect(result).to be_success
      end
    end

    it "does not flag implicit-self calls (the rule is explicit-receiver only)" do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, "self.rb")
        File.write(source_path, <<~RUBY)
          class Foo
            def bar
              helper(1)
            end

            def helper(_n); end
          end
        RUBY

        configuration = Rigor::Configuration.new("paths" => [dir])
        result = described_class.new(configuration: configuration).run

        expect(result).to be_success
      end
    end

    it "does not flag calls on Dynamic[Top] receivers" do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, "dyn.rb")
        File.write(source_path, "def f(x); x.anything; end\n")

        configuration = Rigor::Configuration.new("paths" => [dir])
        result = described_class.new(configuration: configuration).run

        expect(result).to be_success
      end
    end

    it "skips classes whose RBS definition cannot be built (constant-decl aliases like YAML)" do
      Dir.mktmpdir do |dir|
        source_path = File.join(dir, "yaml.rb")
        File.write(source_path, "YAML.dump({})\nYAML.safe_load_file(\"x\")\n")

        configuration = Rigor::Configuration.new("paths" => [dir])
        result = described_class.new(configuration: configuration).run

        expect(result).to be_success
      end
    end

    describe "wrong-arity rule (Slice 7 phase 11)" do
      it "flags too many positional arguments to a fixed-arity method" do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, "rotate.rb")
          File.write(source_path, "[1, 2].rotate(1, 2)\n")

          configuration = Rigor::Configuration.new("paths" => [dir])
          result = described_class.new(configuration: configuration).run

          diag = result.diagnostics.find { |d| d.message.include?("rotate") }
          expect(diag).not_to be_nil
          expect(diag.message).to include("expected 0..1")
          expect(diag.message).to include("given 2")
        end
      end

      it "flags too few positional arguments to a method with required args" do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, "fetch.rb")
          File.write(source_path, "[1, 2].fetch\n")

          configuration = Rigor::Configuration.new("paths" => [dir])
          result = described_class.new(configuration: configuration).run

          diag = result.diagnostics.find { |d| d.message.include?("fetch") }
          expect(diag).not_to be_nil
          expect(diag.message).to include("expected 1..2")
          expect(diag.message).to include("given 0")
        end
      end

      it "does not flag a call whose argument count fits the envelope" do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, "ok.rb")
          File.write(source_path, "[1, 2, 3].rotate(1)\n[1].fetch(0)\n")

          configuration = Rigor::Configuration.new("paths" => [dir])
          result = described_class.new(configuration: configuration).run

          expect(result).to be_success
        end
      end

      it "skips calls with splat arguments (caller arity unknown)" do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, "splat.rb")
          File.write(source_path, "args = [1]; [1].rotate(*args)\n")

          configuration = Rigor::Configuration.new("paths" => [dir])
          result = described_class.new(configuration: configuration).run

          expect(result).to be_success
        end
      end

      it "suppresses the diagnostic when the method is defined via def in source" do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, "extended.rb")
          File.write(source_path, <<~RUBY)
            class String
              def my_extension; self; end
            end

            "x".my_extension
          RUBY

          configuration = Rigor::Configuration.new("paths" => [dir])
          result = described_class.new(configuration: configuration).run

          expect(result).to be_success
        end
      end

      it "suppresses the diagnostic when the method is defined via define_method" do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, "dm.rb")
          File.write(source_path, <<~RUBY)
            class String
              define_method(:special) { |x| x }
            end

            "x".special(1)
          RUBY

          configuration = Rigor::Configuration.new("paths" => [dir])
          result = described_class.new(configuration: configuration).run

          expect(result).to be_success
        end
      end

      describe "dump_type / assert_type rules (Slice 7 phase 19)" do # rubocop:disable RSpec/NestedGroups
        it "emits an info-severity diagnostic for `dump_type(value)`" do
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, "demo.rb"), <<~RUBY)
              require "rigor/testing"
              include Rigor::Testing
              n = 4
              dump_type(n)
            RUBY

            configuration = Rigor::Configuration.new("paths" => [dir])
            result = described_class.new(configuration: configuration).run

            dump = result.diagnostics.find { |d| d.message.start_with?("dump_type") }
            expect(dump).not_to be_nil
            expect(dump.severity).to eq(:info)
            expect(dump.message).to include("4")
            # info-severity does not fail the run.
            expect(result).to be_success
          end
        end

        it "errors on `assert_type` mismatch and stays silent on a match" do # rubocop:disable RSpec/ExampleLength
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, "match.rb"), <<~RUBY)
              require "rigor/testing"
              include Rigor::Testing
              x = 4
              assert_type("4", x)
            RUBY
            File.write(File.join(dir, "miss.rb"), <<~RUBY)
              require "rigor/testing"
              include Rigor::Testing
              x = 4
              assert_type("Integer", x)
            RUBY

            configuration = Rigor::Configuration.new("paths" => [dir])
            result = described_class.new(configuration: configuration).run

            mismatch = result.diagnostics.find { |d| d.message.start_with?("assert_type mismatch") }
            expect(mismatch).not_to be_nil
            expect(mismatch.path).to end_with("miss.rb")
            expect(mismatch.message).to include('expected "Integer"')
            expect(mismatch.message).to include('got "4"')
          end
        end
      end

      describe "nil-receiver rule (Slice 7 phase 14)" do # rubocop:disable RSpec/NestedGroups
        it "flags a call to a method that does not exist on NilClass when receiver is T | nil" do
          Dir.mktmpdir do |dir|
            source_path = File.join(dir, "nil.rb")
            File.write(source_path, <<~RUBY)
              x = if rand < 0.5
                "hello"
              else
                nil
              end
              x.upcase
            RUBY

            configuration = Rigor::Configuration.new("paths" => [dir])
            result = described_class.new(configuration: configuration).run

            diag = result.diagnostics.find { |d| d.message.include?("nil receiver") }
            expect(diag).not_to be_nil
            expect(diag.message).to include("upcase")
          end
        end

        it "does not flag a method that NilClass also has (e.g. to_s)" do
          Dir.mktmpdir do |dir|
            source_path = File.join(dir, "ok.rb")
            File.write(source_path, <<~RUBY)
              x = if rand < 0.5
                "hello"
              else
                nil
              end
              x.to_s
            RUBY

            configuration = Rigor::Configuration.new("paths" => [dir])
            result = described_class.new(configuration: configuration).run

            expect(result).to be_success
          end
        end

        it "does not flag safe-navigation calls (`x&.method`)" do
          Dir.mktmpdir do |dir|
            source_path = File.join(dir, "safe.rb")
            File.write(source_path, <<~RUBY)
              x = if rand < 0.5
                "hello"
              else
                nil
              end
              x&.upcase
            RUBY

            configuration = Rigor::Configuration.new("paths" => [dir])
            result = described_class.new(configuration: configuration).run

            expect(result).to be_success
          end
        end

        it "is suppressed when an early-return guard narrows nil out (Slice 7 phase 14 narrowing)" do # rubocop:disable RSpec/ExampleLength
          Dir.mktmpdir do |dir|
            source_path = File.join(dir, "guard.rb")
            File.write(source_path, <<~RUBY)
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

            configuration = Rigor::Configuration.new("paths" => [dir])
            result = described_class.new(configuration: configuration).run

            expect(result).to be_success
          end
        end
      end

      it "skips methods with required keyword arguments" do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, "kw.rb")
          File.write(source_path, "[1, 2].push(1)\n")

          configuration = Rigor::Configuration.new("paths" => [dir])
          result = described_class.new(configuration: configuration).run

          expect(result).to be_success
        end
      end
    end
  end
end
