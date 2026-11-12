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

  # #2586 — the single derivation `rigor check`, pooled workers and `rigor unused`'s plugin roots share.
  describe ".for_configuration" do
    it "derives trusted gems, read roots, and the network policy from the configuration" do
      Dir.mktmpdir do |dir|
        sig_dir = File.join(dir, "sig")
        FileUtils.mkdir_p(sig_dir)
        extra_dir = File.join(dir, "extra")
        FileUtils.mkdir_p(extra_dir)
        configuration = Rigor::Configuration.new(
          "signature_paths" => [sig_dir],
          "plugins" => ["rigor-a", { "gem" => "rigor-b" }, { "id" => "rigor-c" }],
          "plugins_io" => { "allowed_paths" => [extra_dir], "network" => "allowlist",
                            "allowed_url_hosts" => ["example.com"] }
        )
        allow(Gem).to receive(:loaded_specs).and_return({})

        expected_pwd = nil
        policy = Dir.chdir(dir) do
          expected_pwd = Dir.pwd
          described_class.for_configuration(configuration)
        end

        expect(policy.trusted_gems).to eq(%w[rigor-a rigor-b rigor-c])
        expect(policy.allowed_read_roots).to include(
          expected_pwd, File.expand_path(sig_dir), File.expand_path(extra_dir)
        )
        expect(policy.network_policy).to eq(:allowlist)
        expect(policy.allowed_url_hosts).to eq(["example.com"])
      end
    end

    it "appends a trusted gem's own full_gem_path to the allowed read roots when it is actually installed" do
      configuration = Rigor::Configuration.new("plugins" => ["rigor-installed"])
      fake_spec = instance_double(Gem::Specification, full_gem_path: "/gems/rigor-installed")
      allow(Gem).to receive(:loaded_specs).and_return({ "rigor-installed" => fake_spec })

      policy = described_class.for_configuration(configuration)

      expect(policy.allowed_read_roots).to include("/gems/rigor-installed")
    end

    describe "the private entry/gem-name helpers" do
      it "trusted_gem_name returns a String entry unchanged" do
        expect(described_class.send(:trusted_gem_name, "rigor-x")).to eq("rigor-x")
      end

      it "trusted_gem_name reads the \"gem\" key from a Hash entry" do
        expect(described_class.send(:trusted_gem_name, { "gem" => "rigor-x", "id" => "x" })).to eq("rigor-x")
      end

      it "trusted_gem_name falls back to the \"id\" key when a Hash entry has no \"gem\" key" do
        expect(described_class.send(:trusted_gem_name, { "id" => "rigor-x" })).to eq("rigor-x")
        expect(described_class.send(:trusted_gem_name, { "gem" => nil, "id" => "rigor-x" })).to eq("rigor-x")
      end

      it "trusted_gem_name returns nil for an entry that is neither a String nor a Hash" do
        expect(described_class.send(:trusted_gem_name, 42)).to be_nil
      end

      it "trusted_gem_root returns nil for a nil or empty gem_name" do
        expect(described_class.send(:trusted_gem_root, nil)).to be_nil
        expect(described_class.send(:trusted_gem_root, "")).to be_nil
      end

      it "trusted_gem_root returns the loaded spec's full_gem_path for an installed gem" do
        fake_spec = instance_double(Gem::Specification, full_gem_path: "/gems/rigor-x")
        allow(Gem).to receive(:loaded_specs).and_return({ "rigor-x" => fake_spec })

        expect(described_class.send(:trusted_gem_root, "rigor-x")).to eq("/gems/rigor-x")
      end

      it "trusted_gem_root returns nil for a gem_name Gem.loaded_specs has never heard of" do
        allow(Gem).to receive(:loaded_specs).and_return({})

        expect(described_class.send(:trusted_gem_root, "rigor-unknown")).to be_nil
      end

      # Mutant: dropping the `rescue StandardError` would propagate a spec lookup failure straight out of
      # trust-policy construction, aborting the whole run over one misbehaving gemspec.
      it "trusted_gem_root returns nil rather than raising when reading full_gem_path itself raises" do
        fake_spec = instance_double(Gem::Specification)
        allow(fake_spec).to receive(:full_gem_path).and_raise(StandardError, "corrupt gemspec")
        allow(Gem).to receive(:loaded_specs).and_return({ "rigor-x" => fake_spec })

        expect(described_class.send(:trusted_gem_root, "rigor-x")).to be_nil
      end
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
