# frozen_string_literal: true

require "rigor/configuration"
require "rigor/effects/entry_points"
require "rigor/effects/snapshot"

# ADR-103 WD14 — the named entry-point presets `effects.snapshot.reach:` may adopt. Presets are supplied
# by the plugin that models a framework (#387), so `Configuration` checks a `reach:` entry's SHAPE and
# `Snapshot.expand_reach` checks its EXISTENCE — the first moment the registered set is complete, because
# plugins load from the very configuration being validated.
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

    # #387 — presets are named by plugins, and plugins load FROM the configuration being validated, so at
    # load time nothing is registered yet. The shape check stays here; the existence check moved to
    # `Snapshot.expand_reach`, which runs once the plugin set is complete.
    it "accepts a well-formed preset name no plugin has registered yet" do
      expect(configuration(["rails"]).effects_snapshot_reach).to eq(["rails"])
    end

    it "rejects a name that is neither a glob nor a well-formed preset name" do
      expect { configuration(["Rails Actions"]) }
        .to raise_error(ArgumentError, /neither a file glob nor a well-formed entry-point preset name/)
    end

    it "is the snapshot that rejects a preset nothing registered" do
      expect do
        Rigor::Effects::Snapshot.build(table: Rigor::Effects::EffectTable.empty, sources: {},
                                       configuration: configuration(["rails"]))
      end
        .to raise_error(described_class::UnknownPreset, /no registered entry-point preset: "rails"/)
    end

    # #433 — the rejection is a mistake in `.rigor.yml`, so it carries the class the CLI renders as a
    # `rigor:` line rather than the one reserved for a plugin's own registration going wrong.
    it "raises a configuration error, not the registration error" do
      expect(described_class::UnknownPreset.ancestors).to include(Rigor::ConfigurationError)
      expect(described_class::Error.ancestors).not_to include(Rigor::ConfigurationError)
    end
  end

  # #433 / #436 — the enumeration both the unregistered-preset error and `rigor effects update`'s
  # empty-`reach:` note read, so neither can answer "which presets may I write?" on its own.
  describe ".availability" do
    it "names the presets this project's plugins registered" do
      described_class.register("rails-mailers", ["app/mailers/**/*.rb"])
      described_class.register("rails-controllers", ["app/controllers/**/*.rb"])

      expect(described_class.availability)
        .to eq("presets registered in this project: rails-controllers, rails-mailers")
    end

    it "says how a preset comes to exist when the project has none" do
      expect(described_class.availability)
        .to include("no plugin in this project registers an entry-point preset", "`plugins:`")
    end
  end

  describe ".resolve!" do
    it "returns the globs of a registered preset" do
      described_class.register("actions", ["app/controllers/**/*.rb"])

      expect(described_class.resolve!("actions")).to eq(["app/controllers/**/*.rb"])
    end

    it "answers an unregistered name with what this project could have written instead" do
      described_class.register("rails-controllers", ["app/controllers/**/*.rb"])

      expect { described_class.resolve!("rails") }
        .to raise_error(described_class::UnknownPreset,
                        'effects.snapshot.reach names no registered entry-point preset: "rails" ' \
                        "(presets registered in this project: rails-controllers)")
    end
  end
end
