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
  end
end
