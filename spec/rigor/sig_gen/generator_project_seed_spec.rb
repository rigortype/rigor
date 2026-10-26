# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #2300 — sig-gen indexes every file over the project's discovery tables, less the member layouts, so a
# helper, an ancestor or a constant another file defines resolves as it does under `rigor check`.
RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def run_over(paths)
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => paths))
    described_class.new(configuration: configuration, paths: paths).run
  end

  def row(candidates, class_name, method_name, kind = :instance)
    candidates.find do |candidate|
      candidate.class_name == class_name && candidate.method_name == method_name && candidate.kind == kind
    end
  end

  it "types a call to a helper another file defines" do
    candidates = run_over([
                            write_fixture("lib/util.rb", "module Util\n  def self.label = \"s\"\nend\n"),
                            write_fixture("lib/user.rb", "class User\n  def name = Util.label\nend\n")
                          ])

    expect(row(candidates, "User", :name).rbs).to eq('def name: () -> "s"')
  end

  it "declines a value another file's subclass overrides, instead of writing the base's own answer" do
    candidates = run_over([
                            write_fixture("lib/field.rb", <<~RUBY),
                              module M
                                class Field
                                  def self.singular?
                                    false
                                  end

                                  def singular?
                                    self.class.singular?
                                  end
                                end
                              end
                            RUBY
                            write_fixture("lib/to_field.rb", <<~RUBY)
                              module M
                                class ToField < Field
                                  def self.singular?
                                    true
                                  end
                                end
                              end
                            RUBY
                          ])

    expect(row(candidates, "M::Field", :singular?).classification).to eq(Rigor::SigGen::Classification::SKIPPED)
  end

  it "keeps the member layouts per file, so a value class is written once" do
    candidates = run_over([
                            write_fixture("lib/point.rb", "Point = Data.define(:x, :y)\n"),
                            write_fixture("lib/other.rb", "class Other\n  def size = 1\nend\n")
                          ])

    expect(candidates.count { |candidate| candidate.class_name == "Point" && candidate.method_name == :x }).to eq(1)
  end

  describe "the run's return memo" do
    around do |example|
      Rigor::Inference::BudgetTrace.enable!
      Rigor::Inference::BudgetTrace.reset
      example.run
    ensure
      Rigor::Inference::BudgetTrace.disable!
      Rigor::Inference::BudgetTrace.reset
    end

    it "infers a helper another file defines once for every file that calls it" do
      paths = [write_fixture("lib/util.rb", "module Util\n  def self.label = [1, 2].map(&:to_s)\nend\n")] +
              %w[a b c].map do |name|
                write_fixture("lib/#{name}.rb", "class #{name.upcase}\n  def label = Util.label\nend\n")
              end
      candidates = run_over(paths)

      evals = Rigor::Inference::BudgetTrace.distribution(Rigor::Inference::BudgetTrace::MEMO_BODY_EVAL_BY_SIGNATURE)
      expect(evals.select { |signature, _| signature.include?("label") && signature.include?("Util") }.values)
        .to eq([1])
      expect(%w[A B C].map { |name| row(candidates, name, :label).rbs })
        .to all(eq(%(def label: () -> ["1", "2"])))
    end
  end
end
