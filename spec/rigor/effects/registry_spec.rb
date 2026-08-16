# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Rigor::Effects::Registry do
  # A small hand-built vocabulary, so the unit behaviour is asserted independently of the shipped
  # data file (whose contents are pinned in `registry_data_spec.rb`).
  let(:registry) do
    described_class.new(vocabulary_version: 1, labels: %w[io io.net.http email.send mutate.local], retired: {})
  end

  describe "#known?" do
    it "recognises a declared label" do
      expect(registry.known?("io.net.http")).to be(true)
      expect(registry.known?("email.send")).to be(true)
    end

    it "recognises an ancestor of a declared label, spelled out or not" do
      # A bound may name an interior node: `io.net` is recognised because `io.net.http` exists,
      # and `email` because `email.send` does.
      expect(registry.known?("io.net")).to be(true)
      expect(registry.known?("email")).to be(true)
      expect(registry.known?("mutate")).to be(true)
    end

    it "does not recognise a descendant of a declared label" do
      # Subsumption lets a declared bound admit an unregistered descendant; the vocabulary itself
      # is still a closed list.
      expect(registry.known?("io.net.http.get")).to be(false)
    end

    it "does not recognise a string-prefix neighbour" do
      expect(registry.known?("iota")).to be(false)
    end

    it "does not recognise a malformed label" do
      expect(registry.known?("IO")).to be(false)
      expect(registry.known?("")).to be(false)
    end
  end

  describe "#labels and #roots" do
    it "lists the declared rows sorted, without the implied ancestors" do
      expect(registry.labels).to eq(%w[email.send io io.net.http mutate.local])
    end

    it "lists the roots, including one that is only implied" do
      expect(registry.roots).to eq(%w[email io mutate])
    end

    it "returns frozen collections" do
      expect(registry.labels).to be_frozen
      expect(registry.roots).to be_frozen
    end
  end

  describe "#suggest" do
    it "proposes the nearest known label for a near miss" do
      expect(registry.suggest("io.net.htp")).to eq("io.net.http")
      expect(registry.suggest("emial.send")).to eq("email.send")
    end

    it "declines when nothing is within the distance cap" do
      expect(registry.suggest("acme.telemetry.pipeline")).to be_nil
    end

    it "declines for a label the vocabulary already knows" do
      expect(registry.suggest("io")).to be_nil
      expect(registry.suggest("io.net")).to be_nil
    end

    it "declines for a malformed label" do
      expect(registry.suggest("IO.NET")).to be_nil
    end
  end

  describe "#retired" do
    let(:registry) do
      described_class.new(
        vocabulary_version: 2,
        labels: %w[io.db.read io.db.write],
        retired: { "io.sql" => %w[io.db.read io.db.write] }
      )
    end

    it "maps a retired spelling to its replacements" do
      expect(registry.retired("io.sql")).to eq(%w[io.db.read io.db.write])
    end

    it "is nil for a spelling that was never retired" do
      expect(registry.retired("io.db.read")).to be_nil
    end

    it "does not make a retired spelling known again" do
      expect(registry.known?("io.sql")).to be(false)
    end
  end

  describe "#with" do
    it "adds a leaf under an existing root" do
      extended = registry.with(labels: %w[io.net.http2], owner: "rigor-httpx")

      expect(extended.known?("io.net.http2")).to be(true)
      expect(extended.labels).to include("io.net.http2")
    end

    it "lets a non-project extender open the root it owns" do
      extended = registry.with(labels: %w[rails.activejob.enqueue], owner: "rails")

      expect(extended.known?("rails.activejob.enqueue")).to be(true)
      expect(extended.roots).to include("rails")
    end

    it "refuses a root the extender does not own" do
      expect { registry.with(labels: %w[acme.cache], owner: "rigor-httpx") }
        .to raise_error(described_class::OwnershipError, /acme/)
    end

    it "lets the project — a nil owner — open any root" do
      extended = registry.with(labels: %w[acme.cache], owner: nil)

      expect(extended.known?("acme.cache")).to be(true)
    end

    it "refuses a label that is not well-formed" do
      expect { registry.with(labels: %w[io.Net], owner: nil) }
        .to raise_error(described_class::InvalidLabelError, /well-formed effect label/)
    end

    it "returns a new registry and leaves the receiver alone" do
      extended = registry.with(labels: %w[io.net.http2], owner: nil)

      expect(extended).not_to be(registry)
      expect(registry.known?("io.net.http2")).to be(false)
    end

    it "carries the vocabulary version and the retired table across" do
      base = described_class.new(vocabulary_version: 3, labels: %w[io], retired: { "io.sql" => %w[io.db] })
      extended = base.with(labels: %w[io.fifo], owner: nil)

      expect(extended.vocabulary_version).to eq(3)
      expect(extended.retired("io.sql")).to eq(%w[io.db])
    end
  end

  describe "value-object discipline" do
    it "is frozen" do
      expect(registry).to be_frozen
    end
  end

  describe ".load_file" do
    it "reads the vocabulary version, the labels and the retired table" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "registry.yml")
        File.write(path, <<~YAML)
          vocabulary: 4
          labels:
            - io
            - io.db.read
          retired:
            io.sql:
              - io.db.read
        YAML

        loaded = described_class.load_file(path)

        expect(loaded.vocabulary_version).to eq(4)
        expect(loaded.labels).to eq(%w[io io.db.read])
        expect(loaded.retired("io.sql")).to eq(%w[io.db.read])
      end
    end

    it "degrades to an empty vocabulary when the file is absent" do
      # Fail-open: every label then reads as unknown, which makes every tag ⊤ rather than raising
      # in a bare install that opted the data out.
      loaded = described_class.load_file(File.join(Dir.tmpdir, "rigor-effects-registry-absent.yml"))

      expect(loaded.labels).to eq([])
      expect(loaded.known?("io")).to be(false)
    end
  end

  describe ".default" do
    it "memoises one shared instance" do
      first = described_class.default

      expect(described_class.default).to be(first)
    end

    it "loads the shipped vocabulary rather than degrading to an empty one" do
      expect(described_class.default.labels).not_to be_empty
    end
  end
end
