# frozen_string_literal: true

require "rigor/configuration"
require "rigor/effects/entry_points"

# ADR-103 WD14 — the named entry-point presets `effects.snapshot.reach:` may adopt. This slice ships none;
# what it ships is the shape, so a name that resolves to nothing is a load-time error rather than a
# `reach:` table that comes back mysteriously empty.
RSpec.describe Rigor::Effects::EntryPoints do
  around do |example|
    described_class.reset!
    example.run
    described_class.reset!
  end

  it "ships no presets" do
    expect(described_class.names).to be_empty
  end

  describe ".glob?" do
    it "reads anything carrying a path or glob character as a glob" do
      expect(described_class).to be_glob("app/**/*.rb")
      expect(described_class).to be_glob("app.rb")
      expect(described_class).to be_glob("lib/thing")
    end

    it "reads a bare token as a preset name" do
      expect(described_class).not_to be_glob("rails-actions")
    end
  end

  describe ".register" do
    it "records the globs a name stands for" do
      described_class.register("rails-actions", ["app/controllers/**/*.rb"])

      expect(described_class).to be_known("rails-actions")
      expect(described_class.globs_for("rails-actions")).to eq(["app/controllers/**/*.rb"])
    end

    # A plugin loaded twice in one process must not raise; a plugin redefining someone else's preset must.
    it "accepts an identical re-registration and rejects a conflicting one" do
      described_class.register("actions", ["a.rb"])

      expect { described_class.register("actions", ["a.rb"]) }.not_to raise_error
      expect { described_class.register("actions", ["b.rb"]) }.to raise_error(described_class::Error)
    end

    it "rejects a name that could never be told from a glob" do
      expect { described_class.register("app/*.rb", ["a.rb"]) }.to raise_error(described_class::Error)
    end
  end

  # Tier 2 (`ArgumentError`, the run stops): the value is one the snapshot commands cannot proceed on.
  describe "through effects.snapshot.reach:" do
    def configuration(reach)
      Rigor::Configuration.new({ "effects" => { "snapshot" => { "reach" => reach } } })
    end

    it "accepts a registered preset name and a glob" do
      described_class.register("actions", ["app/controllers/**/*.rb"])

      expect(configuration(["actions", "lib/**/*.rb"]).effects_snapshot_reach)
        .to eq(["actions", "lib/**/*.rb"])
    end

    it "rejects an unknown preset name, naming the known set" do
      expect { configuration(["rails"]) }
        .to raise_error(ArgumentError, /no known entry-point preset: "rails".*known presets: \[\]/m)
    end
  end
end
