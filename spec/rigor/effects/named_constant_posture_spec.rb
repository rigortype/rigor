# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"

# ADR-103 #463 — a catalogue posture on a receiver the **syntax** names.
#
# `UnitScan#catalog_target` has always trusted a written constant path for the row lookup, while
# `posture_allowed?` refused the class's posture whenever the typer's receiver type was `Dynamic`. The
# rationale for that refusal — "the class the typer projected to is a guess" — does not hold for a
# constant the author wrote, and the two disagreeing made the catalogue's reach a function of whether
# the bundled rbs happens to ship a signature: `Net::HTTP.get` proved `io.net.http` and `Net::IMAP.new`
# proved nothing, which is why the `Net::FTP` row had never once fired.
RSpec.describe "a catalogue posture on a syntactically named constant" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/named_constant", __dir__)
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

  it "lets the class's posture answer for a constant the source names" do
    expect(table["NamedConstant::Written#connect"].proven.to_a).to eq(["io.net"])
  end

  # And it DISCHARGES, like every other catalogue claim. A `dynamic-receiver` taint is about the class
  # the typer projected being a guess, and on a constant path there is no projection to guess at: the
  # receiver of `Net::IMAP.new` is that constant, exactly. What the posture then asserts — that every
  # method of this class contributes at most `io.net` — is the hand-audited claim the catalogue is made
  # of, and it is the same claim `Socket#connect` rests on when the typer did name the receiver.
  it "leaves the site exhaustive, as any other catalogue claim does" do
    expect(table["NamedConstant::Written#connect"]).to be_exhaustive
  end

  # The exclusion the rule exists for, unchanged: `Kernel`'s instance posture is the whole outside
  # world, and an unqualified call spells `Kernel#name`.
  it "still refuses the posture for an implicit-self call" do
    expect(table["NamedConstant::Implicit#run"].proven).to be_empty
  end

  # `send` and friends are excluded whatever named the receiver: their own reading of the site is the
  # more specific one. A literal selector is an ordinary edge rather than a taint, so the observable
  # here is that the class's posture did not answer.
  it "still refuses the posture for a deferred selector" do
    expect(table["NamedConstant::Deferred#run"].proven).to be_empty
  end
end
