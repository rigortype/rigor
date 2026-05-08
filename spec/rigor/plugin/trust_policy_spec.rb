# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::TrustPolicy do
  describe "construction" do
    it "stores trusted gems sorted, deduplicated, and frozen" do
      policy = described_class.new(trusted_gems: %w[rigor-rspec rigor-rails rigor-rspec])
      expect(policy.trusted_gems).to eq(%w[rigor-rails rigor-rspec])
      expect(policy.trusted_gems).to be_frozen
    end

    it "expands allowed_read_roots to absolute paths" do
      Dir.mktmpdir do |dir|
        policy = described_class.new(allowed_read_roots: [dir, "."])
        expect(policy.allowed_read_roots).to include(File.expand_path(dir))
        expect(policy.allowed_read_roots.first).to start_with("/")
      end
    end

    it "rejects unknown network policies" do
      expect { described_class.new(network_policy: :allowed) }.to raise_error(ArgumentError, /must be one of/)
    end

    it "is frozen after construction" do
      expect(described_class.new).to be_frozen
    end
  end

  describe "#allow_read?" do
    let(:policy) do
      Dir.mktmpdir do |dir|
        @root = dir
        described_class.new(allowed_read_roots: [dir])
      end
    end

    it "permits a path inside an allowed root" do
      Dir.mktmpdir do |root|
        nested = File.join(root, "nested.rb")
        FileUtils.touch(nested)
        policy = described_class.new(allowed_read_roots: [root])
        expect(policy.allow_read?(nested)).to be(true)
      end
    end

    it "permits the root itself" do
      Dir.mktmpdir do |root|
        policy = described_class.new(allowed_read_roots: [root])
        expect(policy.allow_read?(root)).to be(true)
      end
    end

    it "denies a sibling that shares the same prefix without a separator" do
      Dir.mktmpdir do |parent|
        root = File.join(parent, "alpha")
        FileUtils.mkdir(root)
        sibling = File.join(parent, "alpha-extra")
        FileUtils.mkdir(sibling)

        policy = described_class.new(allowed_read_roots: [root])
        expect(policy.allow_read?(File.join(sibling, "x.rb"))).to be(false)
      end
    end

    it "denies a path outside every allowed root" do
      Dir.mktmpdir do |root|
        policy = described_class.new(allowed_read_roots: [root])
        expect(policy.allow_read?("/etc/hosts")).to be(false)
      end
    end
  end

  describe "#network_allowed?" do
    it "is false while the policy is :disabled" do
      expect(described_class.new(network_policy: :disabled).network_allowed?).to be(false)
    end

    it "is true while the policy is :allowlist" do
      expect(described_class.new(network_policy: :allowlist).network_allowed?).to be(true)
    end
  end

  describe "#allow_url? (v0.1.2)" do
    it "is false while the policy is :disabled" do
      policy = described_class.new(network_policy: :disabled, allowed_url_hosts: %w[example.com])
      expect(policy.allow_url?("https://example.com/foo")).to be(false)
    end

    it "is true for an HTTPS URL whose host is on the allowlist" do
      policy = described_class.new(network_policy: :allowlist, allowed_url_hosts: %w[example.com])
      expect(policy.allow_url?("https://example.com/foo")).to be(true)
    end

    it "is false for a URL whose host is not on the allowlist" do
      policy = described_class.new(network_policy: :allowlist, allowed_url_hosts: %w[example.com])
      expect(policy.allow_url?("https://other.invalid/foo")).to be(false)
    end

    it "rejects HTTP (non-HTTPS) URLs" do
      policy = described_class.new(network_policy: :allowlist, allowed_url_hosts: %w[example.com])
      expect(policy.allow_url?("http://example.com/foo")).to be(false)
    end

    it "matches host case-insensitively" do
      policy = described_class.new(network_policy: :allowlist, allowed_url_hosts: %w[Example.COM])
      expect(policy.allow_url?("https://EXAMPLE.com/foo")).to be(true)
    end

    it "rejects a malformed URL string instead of raising" do
      policy = described_class.new(network_policy: :allowlist, allowed_url_hosts: %w[example.com])
      expect(policy.allow_url?("not a url")).to be(false)
    end

    it "is false when the allowlist is empty even under :allowlist policy" do
      policy = described_class.new(network_policy: :allowlist, allowed_url_hosts: [])
      expect(policy.allow_url?("https://example.com/foo")).to be(false)
    end
  end

  describe "#gem_trusted?" do
    it "matches a registered gem regardless of input type" do
      policy = described_class.new(trusted_gems: %w[rigor-rspec])
      expect(policy.gem_trusted?("rigor-rspec")).to be(true)
      expect(policy.gem_trusted?(:"rigor-rspec")).to be(true)
      expect(policy.gem_trusted?("other")).to be(false)
    end
  end

  describe "#to_h" do
    it "renders the policy as a serialisable Hash" do
      Dir.mktmpdir do |root|
        policy = described_class.new(
          trusted_gems: %w[rigor-rails],
          allowed_read_roots: [root],
          network_policy: :allowlist,
          allowed_url_hosts: %w[example.com]
        )
        h = policy.to_h
        expect(h["trusted_gems"]).to eq(%w[rigor-rails])
        expect(h["allowed_read_roots"]).to include(File.expand_path(root))
        expect(h["network_policy"]).to eq("allowlist")
        expect(h["allowed_url_hosts"]).to eq(%w[example.com])
      end
    end
  end
end
