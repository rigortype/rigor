# frozen_string_literal: true

# Gates tool/spec_costs.tsv, the per-file cost table `bin/verify-changed` budgets a
# mirror directory with (#3289), and the refresh that rewrites it.
require "fileutils"
require "json"
require "tmpdir"
require "spec_helper"
require_relative "../../tool/spec_costs"

RSpec.describe SpecCosts do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:text) { File.read(File.join(root, SpecCosts::TABLE)) }
  let(:rows) { described_class.parse(text) }
  let(:script) { File.read(File.join(root, "bin/verify-changed")) }

  def script_number(name) = Float(script[/^#{name}=([\d.]+)$/, 1])

  describe "the checked-in table" do
    it "names the table bin/verify-changed reads" do
      expect(script).to include("spec_cost_table=#{SpecCosts::TABLE}\n")
    end

    it "holds one well-formed row per line, sorted by path, with no duplicate" do
      body = text.each_line.reject { |line| line.start_with?("#") }
      expect(body).not_to be_empty
      expect(body).to all(match(/\A\d+\.\d{2}\t\S+_spec\.rb\n\z/))
      paths = body.map { |line| line.chomp.split("\t", 2).last }
      expect(paths).to eq(paths.uniq.sort)
    end

    # A row for a deleted or renamed spec is tolerated: no lookup reaches it, and the next
    # refresh drops it, so a deletion needs no table edit. A table that is mostly dangling is
    # not that, but a wrong path prefix, and would price everything at the default.
    it "is mostly live: more than half its rows name a spec under or beside a mirror directory" do
      live = rows.keys & described_class.mirrored_specs(root)
      expect(live.length).to be > (rows.length / 2)
    end

    # Coverage is "an entry or the default": a spec the table does not list is priced at
    # the default, so the default must stay at the dear end of what was measured, or a new
    # slow spec would ride in cheaply until the next refresh. Only the lower bound is pinned;
    # the default (10 s) sits well above the measured p90 (~6 s) so a refresh does not force
    # a retune.
    it "prices an unlisted spec at least at the 90th percentile of the measured ones" do
      costs = rows.values.sort
      expect(costs.length).to be > 100
      expect(script_number("spec_cost_default")).to be >= costs[(costs.length * 0.9).floor]
    end

    # Half, not all: new specs ride at the default until a refresh, and no ordinary PR has to
    # add rows. Below half the default is no longer the exception and the table needs one.
    it "lists more than half of the mirrored specs, so the default is the exception" do
      mirrored = described_class.mirrored_specs(root)
      expect((mirrored & rows.keys).length).to be > (mirrored.length / 2)
    end
  end

  describe ".mirror_dirs" do
    it "maps lib/ and tool/ files to their spec directories and never the unit-spec root" do
      dirs = described_class.mirror_dirs(root)
      expect(dirs).to include("spec/rigor/cli", "spec/rigor/analysis/check_rules")
      expect(dirs).not_to include("spec/rigor")
    end
  end

  # A child that dies before its probe writes must record nothing, not the numbers an
  # earlier run left in the same file.
  describe ".measure" do
    let(:failed) { instance_double(Process::Status, success?: false, exitstatus: 1) }

    it "deletes a stale output file before each run" do
      Dir.mktmpdir("spec-costs") do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("tmp")
          File.write("tmp/spec_costs_spec_x.json", JSON.generate("spec/x/old_spec.rb" => 9.0))
          allow(Open3).to receive(:capture3).and_return(["", "boom", failed])
          measured = nil
          expect { measured = described_class.measure(["spec/x"]) }.to output(%r{spec/x: rspec exited 1}).to_stderr
          expect(measured).to eq({})
        end
      end
    end

    it "records what the child wrote" do
      Dir.mktmpdir("spec-costs") do |dir|
        Dir.chdir(dir) do
          allow(Open3).to receive(:capture3) do |env, *|
            File.write(env.fetch("SPEC_COSTS_OUT"), JSON.generate("spec/x/a_spec.rb" => 1.5))
            ["", "", instance_double(Process::Status, success?: true)]
          end
          expect(described_class.measure(["spec/x"])).to eq("spec/x/a_spec.rb" => 1.5)
        end
      end
    end
  end

  describe ".merge" do
    let(:old) { { "spec/a_spec.rb" => 1.0, "spec/b_spec.rb" => 1.0, "spec/gone_spec.rb" => 3.0 } }
    let(:existing) { %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb] }

    # A re-measurement on another host, or under load, moves most files by less than
    # a factor of two; rewriting those rows would make every refresh conflict.
    it "keeps a row within a factor of two, moves one past it, adds new files and drops deleted ones" do
      measured = { "spec/a_spec.rb" => 1.9, "spec/b_spec.rb" => 2.5, "spec/c_spec.rb" => 0.001 }
      merged = described_class.merge(old, measured, existing)
      expect(merged).to eq("spec/a_spec.rb" => 1.0, "spec/b_spec.rb" => 2.5, "spec/c_spec.rb" => 0.01)
    end

    it "moves a row that got more than twice as fast" do
      merged = described_class.merge(old, { "spec/a_spec.rb" => 0.4 }, existing)
      expect(merged["spec/a_spec.rb"]).to eq(0.4)
    end
  end

  it "formats rows the way the table holds them" do
    expect(described_class.format("# h\n", "spec/a_spec.rb" => 1.5)).to eq("# h\n1.50\tspec/a_spec.rb\n")
  end
end
