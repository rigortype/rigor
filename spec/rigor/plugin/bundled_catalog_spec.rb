# frozen_string_literal: true

require "spec_helper"
require "rigor/plugin/bundled_catalog"

RSpec.describe Rigor::Plugin::BundledCatalog do
  before { described_class.reset! }

  # The catalogue is fail-soft by design, so a bundled plugin whose entry file raises simply vanishes from
  # the index — which is how a plugin-gap example came to expect one gem and see none, on one CI shard
  # only. Asserting the recorded failures are empty turns that into a message instead of a bare `[]`.
  it "loads every bundled plugin entry file" do
    expect(described_class.load_failures).to eq({})
  end

  # The counterpart to the assertion above: it discriminates only if a real breakage would be recorded.
  it "records the gem whose entry file raised" do
    allow(described_class).to receive(:require).and_call_original
    allow(described_class).to receive(:require).with(/rigor-sidekiq/).and_raise(LoadError, "kaboom")
    described_class.reset!
    described_class.entries

    expect(described_class.load_failures["rigor-sidekiq"]).to include("kaboom")
  ensure
    described_class.instance_variable_get(:@load_failures).delete("rigor-sidekiq")
  end

  it "reads each bundled plugin's declared target gems off its manifest" do
    entries = described_class.entries

    expect(entries.map(&:gem_name)).to include("rigor-activerecord", "rigor-rspec", "rigor-factorybot")
    expect(entries.find { |e| e.gem_name == "rigor-rspec" }.target_gems).to eq(["rspec-core"])
  end

  it "omits a plugin that models no gem" do
    expect(described_class.entries.map(&:gem_name)).not_to include("rigor-typescript-utility-types")
  end

  it "indexes by gem name, including a plugin whose target is a different gem" do
    expect(described_class.for_gem("railties").map(&:gem_name))
      .to include("rigor-railties", "rigor-rails-routes")
    expect(described_class.for_gem("no-such-gem")).to be_empty
  end

  # A spec-defined `Class.new(Rigor::Plugin::Base)` may reuse a bundled id, and `stub_const` leaves it
  # anonymous but alive once the example ends. Whichever of the two `ObjectSpace` walked first used to win
  # the id, and the throwaway one declares no `target_gems:`.
  it "prefers the bundled plugin class over a loaded impostor sharing its id" do
    described_class.entries
    impostor = Class.new(Rigor::Plugin::Base) { manifest(id: "factorybot", version: "0.0.1") }
    expect(impostor.manifest.target_gems).to be_empty

    # The impostor goes first, which is the walk order the id used to be decided by.
    allow(ObjectSpace).to receive(:each_object).with(Class) do |&block|
      classes = [impostor, Rigor::Plugin::Factorybot]
      block ? classes.each(&block) : classes.each
    end
    described_class.reset!

    expect(described_class.for_gem("factory_bot").map(&:gem_name)).to eq(["rigor-factorybot"])
  end

  # `FirstParty.bundled?` memoises for the process, so one spec stubbing the engine root answers for every
  # later one. The catalogue decides bundledness from the path it required itself.
  it "does not ask FirstParty whether a plugin it just required is bundled" do
    allow(Rigor::Plugin::FirstParty).to receive(:bundled?).and_return(false)
    described_class.reset!

    expect(described_class.entries.map(&:gem_name)).to include("rigor-factorybot")
  end

  describe "independence from the live registry" do
    # `require` is idempotent, so a plugin loaded by an earlier spec and then dropped by
    # `Rigor::Plugin.unregister!` is absent from the registry while still loaded. An index built from the
    # registry at that moment lacked it, and `rigor doctor` then read the project's own enabled plugin as
    # a gap and failed — only on the CI shard where the spec order produced that state.
    it "lists a bundled plugin that is loaded but no longer registered" do
      described_class.entries
      Rigor::Plugin.unregister!
      described_class.reset!

      expect(described_class.for_gem("activerecord").map(&:gem_name)).to include("rigor-activerecord")
    end
  end
end
