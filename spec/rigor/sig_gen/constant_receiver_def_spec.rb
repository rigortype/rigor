# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Issue #2950 — `def M.x` inside `module M` defines a singleton method, as `def self.x` does. sig-gen filed it as an
# instance method, so in mail's `Mail::Utilities` the singleton `Utilities.uri_parser` overwrote the instance
# `uri_parser` proposal and `rigor check` reported `def.return-type-mismatch` on the committed signature.
RSpec.describe "rigor sig-gen on a def whose receiver names the enclosing module (#2950)", type: :runner do
  let(:source) do
    <<~RUBY
      module M
        def parser
          @parser ||= rand.zero? ? 1 : :sym
        end

        def M.parser
          "s"
        end
      end
    RUBY
  end

  def proposals
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "m.rb"), source)
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [lib]))
      Rigor::SigGen::Generator.new(configuration: configuration, paths: [lib]).run
                              .select { |c| c.method_name == :parser }
                              .to_h { |c| [c.kind, c.rbs] }
    end
  end

  it "proposes the instance and singleton methods on their own sides" do
    expect(proposals).to eq(instance: "def parser: () -> (1 | :sym)", singleton: "def self.parser: () -> \"s\"")
  end

  it "leaves rigor check quiet on the committed proposal" do
    rbs = proposals.values.join("\n  ")
    result = analyze(files: { "m.rb" => source }, sig: { "m.rbs" => "module M\n  #{rbs}\nend\n" })
    expect(result.diagnostics.map { |d| d.rule.to_s }).not_to include("def.return-type-mismatch")
  end
end
