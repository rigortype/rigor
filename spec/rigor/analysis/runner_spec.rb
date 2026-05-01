# frozen_string_literal: true

require "tmpdir"
require "rigor/analysis/runner"

RSpec.describe Rigor::Analysis::Runner do
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
