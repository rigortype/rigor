# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require "rigor/signature_path_audit"

RSpec.describe Rigor::SignaturePathAudit do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  describe ".audit" do
    it "returns an empty result for the unset default (nil)" do
      expect(described_class.audit(nil)).to eq([])
    end

    it "returns an empty result for an empty configured list" do
      expect(described_class.audit([])).to eq([])
    end

    it "flags a path that does not exist as :missing" do
      entry = described_class.audit(["/no/such/path/sig"]).fetch(0)

      expect(entry.status).to eq(:missing)
      expect(entry).to be_warning
      expect(entry.rbs_file_count).to eq(0)
      expect(entry.message).to include("does not exist")
    end

    it "flags a directory with no .rbs files as :empty" do
      FileUtils.mkdir_p("emptysig")

      entry = described_class.audit([File.expand_path("emptysig")]).fetch(0)

      expect(entry.status).to eq(:empty)
      expect(entry).to be_warning
      expect(entry.message).to include("matched 0 signature files")
    end

    it "flags an existing non-directory path as :not_directory" do
      File.write("sigs.rbs", "# stub\n")

      entry = described_class.audit([File.expand_path("sigs.rbs")]).fetch(0)

      expect(entry.status).to eq(:not_directory)
      expect(entry).to be_warning
      expect(entry.message).to include("is not a directory")
    end

    it "counts .rbs files (recursively) and reports :ok for a populated directory" do
      FileUtils.mkdir_p("sig/nested")
      File.write("sig/foo.rbs", "class Foo\nend\n")
      File.write("sig/nested/bar.rbs", "class Bar\nend\n")

      entry = described_class.audit([File.expand_path("sig")]).fetch(0)

      expect(entry.status).to eq(:ok)
      expect(entry).not_to be_warning
      expect(entry.rbs_file_count).to eq(2)
      expect(entry.message).to include("loaded 2 signature file")
    end
  end

  describe ".warnings" do
    it "returns only the entries that resolved to nothing" do
      FileUtils.mkdir_p("sig")
      File.write("sig/foo.rbs", "class Foo\nend\n")

      warnings = described_class.warnings([File.expand_path("sig"), "/no/such/path/sig"])

      expect(warnings.map(&:status)).to eq([:missing])
    end
  end

  describe "Entry#to_h" do
    it "serialises the path, status, count, and message for JSON consumers" do
      hash = described_class.audit(["/no/such/path/sig"]).fetch(0).to_h

      expect(hash).to eq(
        "path" => "/no/such/path/sig",
        "status" => "missing",
        "rbs_file_count" => 0,
        "message" => 'signature_paths: "/no/such/path/sig" does not exist (no signatures loaded from it)'
      )
    end
  end

  # Issue #697 — a `signature_paths:` entry that reaches a bundled plugin's own `sig/` while
  # `plugins:` never names it. The RBS loads; the manifest (and with it ADR-26
  # `open_receivers:`) does not, so the plugin's deliberately partial declarations read as
  # complete. The warning is the whole interim fix — the false positive itself is #660's to
  # settle — so the bar these examples hold is that it never fires on a working setup.
  describe ".bundled_plugin_routes" do
    let(:plugin_gem) { "rigor-activerecord" }
    let(:plugin_sig) { described_class.bundled_plugin_sig_dirs.fetch(plugin_gem) }

    it "flags an entry naming a bundled plugin's sig/ that plugins: does not name" do
      routes = described_class.bundled_plugin_routes([plugin_sig], [])

      expect(routes.map(&:gem)).to eq([plugin_gem])
      expect(routes.fetch(0).message).to include(plugin_gem)
      expect(routes.fetch(0).message).to include("Add \"#{plugin_gem}\" to `plugins:`")
    end

    it "flags an ancestor entry that reaches the same signatures" do
      routes = described_class.bundled_plugin_routes([File.dirname(plugin_sig)], [])

      expect(routes.map(&:gem)).to eq([plugin_gem])
    end

    it "flags a subdirectory of the plugin's sig/ that carries signatures" do
      # The question is which of the plugin's `.rbs` files the entry loads, not whether the
      # entry spells the `sig/` directory — a subdirectory loads the partial declarations too.
      nested = Dir.glob(File.join(plugin_sig, "*")).find { |path| File.directory?(path) }

      routes = described_class.bundled_plugin_routes([nested], [])

      expect(routes.map(&:gem)).to eq([plugin_gem])
    end

    it "follows a symlink to the plugin's sig/, because the question is what the entry LOADS" do
      FileUtils.ln_s(plugin_sig, "linked_sig")

      routes = described_class.bundled_plugin_routes([File.expand_path("linked_sig")], [])

      expect(routes.map(&:gem)).to eq([plugin_gem])
    end

    it "stays silent when plugins: names the gem" do
      expect(described_class.bundled_plugin_routes([plugin_sig], [plugin_gem])).to eq([])
    end

    it "stays silent when plugins: names the gem in the hash form" do
      entries = [{ "gem" => plugin_gem, "config" => {} }]

      expect(described_class.bundled_plugin_routes([plugin_sig], entries)).to eq([])
    end

    it "stays silent when plugins: names the manifest id rather than the gem" do
      entries = [{ "id" => plugin_gem.delete_prefix("rigor-") }]

      expect(described_class.bundled_plugin_routes([plugin_sig], entries)).to eq([])
    end

    it "stays silent on the project's own sig/" do
      FileUtils.mkdir_p("sig")
      File.write("sig/app.rbs", "class Post\nend\n")

      expect(described_class.bundled_plugin_routes([File.expand_path("sig")], [])).to eq([])
    end

    it "stays silent on a gem's sig/ that is not a bundled Rigor plugin" do
      FileUtils.mkdir_p("vendor/some_gem/sig")
      File.write("vendor/some_gem/sig/some_gem.rbs", "class SomeGem\nend\n")

      expect(described_class.bundled_plugin_routes([File.expand_path("vendor/some_gem/sig")], [])).to eq([])
    end

    it "stays silent on a path that does not exist" do
      expect(described_class.bundled_plugin_routes(["/no/such/path/sig"], [])).to eq([])
    end

    it "stays silent on an entry naming a file rather than a directory" do
      # The loader `add`s directories only, so a file entry loads nothing and can protect nothing.
      file = Dir.glob(File.join(plugin_sig, "**", "*.rbs")).min

      expect(described_class.bundled_plugin_routes([file], [])).to eq([])
    end

    it "stays silent on a bundled plugin directory that carries no .rbs" do
      lib = File.join(File.dirname(plugin_sig), "lib")

      expect(described_class.bundled_plugin_routes([lib], [])).to eq([])
    end

    it "stays silent for the unset default and for an empty list" do
      expect(described_class.bundled_plugin_routes(nil, [])).to eq([])
      expect(described_class.bundled_plugin_routes([], [])).to eq([])
    end
  end

  # The discovery is re-derived here rather than read off `Plugin::Loader`, because
  # `plugin/registry.rb` resolves `NodeRuleWalk` at load and requiring the loader from a file
  # every `rigor check` loads before the cache probe raises. These pin the duplication so it
  # cannot drift in silence.
  describe "bundled-plugin discovery, against Plugin::Loader" do
    it "anchors the plugins root exactly where the loader does" do
      expect(described_class::BUNDLED_PLUGINS_ROOT)
        .to eq(File.join(Rigor::Plugin::Loader::ENGINE_ROOT, "plugins"))
    end

    it "answers the same sig/ directory the loader answers, for every plugin it finds" do
      dirs = described_class.bundled_plugin_sig_dirs

      expect(dirs).not_to be_empty
      dirs.each do |gem, sig|
        expect(sig).to eq(Rigor::Plugin::Loader.bundled_plugin_sig_path(gem))
      end
    end
  end

  describe "BundledPluginRoute#to_h" do
    it "serialises the path and the gem for JSON consumers" do
      hash = described_class.bundled_plugin_routes(
        [described_class.bundled_plugin_sig_dirs.fetch("rigor-activerecord")], []
      ).fetch(0).to_h

      expect(hash).to include("gem" => "rigor-activerecord")
      expect(hash.fetch("path")).to end_with("plugins/rigor-activerecord/sig")
      expect(hash.fetch("message")).to include("Add \"rigor-activerecord\" to `plugins:`")
    end
  end
end
