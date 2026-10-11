# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/sig_gen/rbs_validity"

# Issue #1794 — `1.step(10, 2)` is `Enumerator::ArithmeticSequence[Integer]` inside the engine, but RBS declares the
# class without a type parameter, so sig-gen MUST write the bare class: `Enumerator::ArithmeticSequence[Integer]`
# does not parse against the core signature.
RSpec.describe "sig-gen arithmetic sequence erasure" do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def rendered(method_name)
    lib = File.join(tmpdir, "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "stepper.rb"), <<~RUBY)
      class Stepper
        def odds = 1.step(10, 2)
        def from(n) = 1.step(n, 2)
      end
    RUBY
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [lib]))
    candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: [lib]).run
    candidates.find { |c| c.method_name == method_name }.rbs
  end

  it "writes the bare class for an Integer step and for an untyped limit" do
    expect(rendered(:odds)).to eq("def odds: () -> Enumerator::ArithmeticSequence")
    expect(rendered(:from)).to eq("def from: (untyped) -> Enumerator::ArithmeticSequence")
    expect(Rigor::SigGen::RbsValidity.method_line_error(rendered(:odds))).to be_nil
  end
end
