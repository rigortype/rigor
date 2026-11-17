# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# `Configuration::Loader` is the class-level loader behind `Configuration.load`. `configuration_spec.rb` pins the
# end-to-end loads (`includes:` merging and path resolution, discovery, auto-wiring); the examples here call the
# loader's own entries, over a temporary directory where one needs files, for what that file does not reach: the
# YAML-read errors, the shape `load_with_includes` answers, and the "already listed" test the CLI shares.
RSpec.describe Rigor::Configuration::Loader do
  def write(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    path
  end

  def error_message(&)
    yield
  rescue Rigor::ConfigurationError => e
    e.message
  end

  describe ".load_with_includes" do
    it "answers the raw hash of a file, with `includes:` consumed and paths made absolute" do
      Dir.mktmpdir do |dir|
        path = write(dir, "a.yml", "includes: []\npaths: [lib]\ncore_root: core\ntarget_ruby: '3.4'\n")
        base = File.absolute_path(dir)
        expect(described_class.load_with_includes(path))
          .to eq({ "paths" => [File.join(base, "lib")], "core_root" => File.join(base, "core"),
                   "target_ruby" => "3.4" })
      end
    end

    it "reads an empty file as an empty hash" do
      Dir.mktmpdir do |dir|
        expect(described_class.load_with_includes(write(dir, "empty.yml", ""))).to eq({})
      end
    end

    it "resolves `plugins_io.allowed_paths:` against the file's own directory" do
      Dir.mktmpdir do |dir|
        path = write(dir, "a.yml", "plugins_io:\n  allowed_paths: [shared]\n  network: allowlist\n")
        expect(described_class.load_with_includes(path)["plugins_io"])
          .to eq({ "allowed_paths" => [File.join(File.absolute_path(dir), "shared")], "network" => "allowlist" })
      end
    end

    it "concatenates `dependencies.source_inference:` across an include rather than overriding it" do
      Dir.mktmpdir do |dir|
        write(dir, "base.yml", "dependencies:\n  source_inference:\n    - {gem: rack, mode: full}\n")
        path = write(dir, "top.yml",
                     "includes: [base.yml]\ndependencies:\n  source_inference:\n    - {gem: faraday, mode: full}\n")
        entries = described_class.load_with_includes(path).dig("dependencies", "source_inference")
        expect(entries.map { |entry| entry["gem"] }).to eq(%w[rack faraday])
      end
    end

    it "lets the including file's scalar win and merges nested hashes key by key" do
      Dir.mktmpdir do |dir|
        write(dir, "base.yml", "cache: {path: base-cache, max_bytes: 10}\ntarget_ruby: '3.3'\n")
        path = write(dir, "top.yml", "includes: [base.yml]\ncache: {path: top-cache}\n")
        expect(described_class.load_with_includes(path))
          .to eq({ "cache" => { "path" => "top-cache", "max_bytes" => 10 }, "target_ruby" => "3.3" })
      end
    end

    it "rejects a file that is not a YAML mapping, naming its absolute path" do
      Dir.mktmpdir do |dir|
        path = write(dir, "list.yml", "- 1\n- 2\n")
        expect(error_message { described_class.load_with_includes(path) })
          .to eq("config file must be a YAML mapping: #{File.absolute_path(path)}")
      end
    end

    it "renders a YAML syntax error as `path:line:column: not valid YAML: ...`" do
      Dir.mktmpdir do |dir|
        path = write(dir, "bad.yml", "a: [unclosed\n")
        expect(error_message { described_class.load_with_includes(path) })
          .to match(/\A#{Regexp.escape(File.absolute_path(path))}:\d+:\d+: not valid YAML: /)
      end
    end

    it "rejects an include chain that loops back, and an include that is missing" do
      Dir.mktmpdir do |dir|
        one = write(dir, "one.yml", "includes: [two.yml]\n")
        write(dir, "two.yml", "includes: [one.yml]\n")
        expect(error_message { described_class.load_with_includes(one) })
          .to eq("circular include: #{File.absolute_path(one)}")
        missing = write(dir, "missing.yml", "includes: [nope.yml]\n")
        expect(error_message { described_class.load_with_includes(missing) })
          .to eq("include not found: \"nope.yml\" (referenced from #{File.dirname(File.absolute_path(missing))})")
      end
    end
  end

  describe ".discover" do
    it "answers the first present candidate in `.rigor.yml`, `.rigor.dist.yml` order, or nil" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(described_class.discover).to be_nil
          File.write(".rigor.dist.yml", "")
          expect(described_class.discover).to eq(".rigor.dist.yml")
          File.write(".rigor.yml", "")
          expect(described_class.discover).to eq(".rigor.yml")
        end
      end
    end
  end

  describe ".rbs_inline_plugin_entry?" do
    it "recognises the gem name and the manifest id, whichever key spelling the Hash uses" do
      expect(described_class.rbs_inline_plugin_entry?("rigor-rbs-inline")).to be(true)
      expect(described_class.rbs_inline_plugin_entry?({ "gem" => "rigor-rbs-inline" })).to be(true)
      expect(described_class.rbs_inline_plugin_entry?({ gem: "rigor-rbs-inline" })).to be(true)
      expect(described_class.rbs_inline_plugin_entry?({ "id" => "rbs-inline" })).to be(true)
      expect(described_class.rbs_inline_plugin_entry?({ id: "rbs-inline" })).to be(true)
    end

    it "does not recognise another plugin or another entry shape" do
      expect(described_class.rbs_inline_plugin_entry?("rigor-rails")).to be(false)
      expect(described_class.rbs_inline_plugin_entry?({ "gem" => "rigor-rails", "id" => "rails" })).to be(false)
      expect(described_class.rbs_inline_plugin_entry?(nil)).to be(false)
      expect(described_class.rbs_inline_plugin_entry?(%w[rigor-rbs-inline])).to be(false)
    end
  end

  describe ".autowire_default_plugins" do
    let(:appended) do
      { "gem" => "rigor-rbs-inline", "id" => "rbs-inline", "config" => { "require_magic_comment" => false } }
    end

    it "appends the plugin, in the annotation-gated mode, when the library resolves and no entry lists it",
       :rbs_inline_autowire do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(true)
      data = { "plugins" => ["rigor-rails"], "paths" => ["lib"] }
      expect(described_class.autowire_default_plugins(data)).to eq({ "plugins" => ["rigor-rails", appended],
                                                                     "paths" => ["lib"] })
      expect(data["plugins"]).to eq(["rigor-rails"])
    end

    it "asks the probe through `Configuration`, so a stub there reaches the gate", :rbs_inline_autowire do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(false)
      data = { "plugins" => [] }
      expect(described_class.autowire_default_plugins(data)).to equal(data)
    end

    it "returns the data untouched when an entry already lists the plugin", :rbs_inline_autowire do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(true)
      data = { "plugins" => [{ "id" => "rbs-inline", "enabled" => false }] }
      expect(described_class.autowire_default_plugins(data)).to equal(data)
    end
  end

  describe "the `Configuration` delegates" do
    it "answer what the loader answers" do
      Dir.mktmpdir do |dir|
        path = write(dir, "a.yml", "paths: [lib]\n")
        expect(Rigor::Configuration.load_with_includes(path)).to eq(described_class.load_with_includes(path))
        expect(Rigor::Configuration.load(path).paths).to eq([File.join(File.absolute_path(dir), "lib")])
      end
      expect(Rigor::Configuration.rbs_inline_plugin_entry?("rigor-rbs-inline")).to be(true)
    end

    it "keeps the auto-wiring names on `Configuration`" do
      expect(Rigor::Configuration::AUTOWIRED_RBS_INLINE_GEM).to equal(described_class::AUTOWIRED_RBS_INLINE_GEM)
      expect(Rigor::Configuration::AUTOWIRED_RBS_INLINE_ID).to equal(described_class::AUTOWIRED_RBS_INLINE_ID)
    end
  end
end
