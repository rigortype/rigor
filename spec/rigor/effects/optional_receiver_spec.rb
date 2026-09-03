# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"

# ADR-103 #455 — a receiver whose type is a union, end to end over the fixture app in
# `spec/integration/fixtures/effects/optional_receiver`. The collector's receiver projection is a small
# mirror of the dispatcher's, and it had no union arm: `T?` — which is what ADR-58 makes of every
# cross-method instance-variable read, and what every `find_by` returns — projected to no class, so the
# call contributed no label and no edge *while the row still read exhaustive*.
RSpec.describe "an effect summary over a union-typed receiver" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/optional_receiver", __dir__)
  end

  def configuration
    data = { "paths" => ["lib"], "parallel" => { "workers" => 0 }, "effects" => {} }
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  let(:table) do
    Dir.chdir(fixture) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      guarded_run(runner, ["lib"])
      runner.effect_table
    end
  end

  # The issue's own reproduction: the same `.read`, once on a `File` and once on the `File | nil` a
  # sibling method's write leaves behind.
  it "reads a cross-method instance variable as its own class" do
    entry = table["OptionalReceiver::IvarReader#read_it"]

    expect(entry.proven.to_a).to eq(["io.fs.read"])
    expect(entry).to be_exhaustive
  end

  it "reads a safe-navigated optional local as its own class" do
    expect(table["OptionalReceiver::SafeNavigator#read_it"].proven.to_a).to eq(["io.fs.read"])
  end

  # A union carrying an arm the typer could not name is the same knowledge as a bare `Dynamic`
  # receiver in a different shape. Empty is allowed; empty AND exhaustive is not.
  it "taints a union with an unnameable arm rather than reading it as effect-free" do
    entry = table["OptionalReceiver::UnknownArm#read_it"]

    expect(entry.proven).to be_empty
    expect(entry).not_to be_exhaustive
    expect(entry.causes.map(&:first)).to include("dynamic-receiver")
  end

  # The residue, asserted so it changes deliberately: both arms perform `io.fs.read` and the record
  # has room for one receiver class, so the site is a miss.
  it "projects nothing when the arms name different classes" do
    expect(table["OptionalReceiver::DisagreeingArms#read_it"].proven).to be_empty
  end
end
