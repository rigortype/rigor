# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/plugins_command"

# `rigor plugins` is a read-only inspection command that loads
# the project's `.rigor.yml`, attempts plugin activation, and
# reports per-plugin status (loaded / load-error) plus every
# manifest-declared extension surface.
#
# The integration-style examples here exercise the real
# `Plugin::Loader` rather than mocking the registry — that is
# the contract the SKILL / `rigor init` / CI consumers actually
# depend on.
RSpec.describe Rigor::CLI::PluginsCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  # Other plugin integration specs in the suite call
  # `Rigor::Plugin.unregister!` in their before/after hooks,
  # which can leave the global registry empty when our spec runs
  # after them. Since `require` is a no-op for an already-loaded
  # plugin file, the file's top-level `Rigor::Plugin.register(...)`
  # call does NOT re-run; the loader then can't match the gem
  # name to a registered class. Re-register the plugins our
  # examples reference so the spec is order-independent.
  before do
    require "rigor-activesupport-core-ext"
    require "rigor-activerecord"
    unless Rigor::Plugin.registered_for("activesupport-core-ext")
      Rigor::Plugin.register(Rigor::Plugin::ActivesupportCoreExt)
    end
    Rigor::Plugin.register(Rigor::Plugin::Activerecord) unless Rigor::Plugin.registered_for("activerecord")
  end

  context "with no plugins configured" do
    before { File.write(".rigor.yml", "paths: [.]\nplugins: []\n") }

    it "renders an empty plugin list and exits 0" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("Plugin activation report")
      expect(out).to include("loaded: 0")
      expect(out).to include("load-error: 0")
    end

    it "emits a JSON report under --format json" do
      status, out, = run(["--format", "json"])
      expect(status).to eq(0)
      parsed = JSON.parse(out)
      expect(parsed.keys).to contain_exactly("configuration", "plugins", "summary")
      expect(parsed["summary"]).to eq({ "total" => 0, "loaded" => 0, "load_error" => 0 })
    end
  end

  context "with a valid bundled plugin" do
    before do
      # Use the explicit gem/id form so the loader's id-based
      # lookup matches the already-registered plugin class even
      # when the require is a no-op (the plugin gets eager-loaded
      # by other specs in the suite; `require` is idempotent
      # which makes the loader's bare-string newly_registered
      # detector miss).
      File.write(".rigor.yml", <<~YAML)
        paths: [.]
        plugins:
          - gem: rigor-activesupport-core-ext
            id: activesupport-core-ext
      YAML
    end

    it "reports the plugin as loaded with its manifest fields" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("loaded: 1")
      expect(out).to include("activesupport-core-ext")
      expect(out).to include("signature_paths:")
      expect(out).to match(%r{rigor-activesupport-core-ext/sig.*\.rbs file})
    end

    it "exposes the manifest fields in JSON" do
      status, out, = run(["--format", "json"])
      expect(status).to eq(0)
      parsed = JSON.parse(out)
      plugin = parsed["plugins"].first
      expect(plugin["status"]).to eq("loaded")
      expect(plugin["id"]).to eq("activesupport-core-ext")
      expect(plugin["signature_paths"].first).to include("rbs_files" => be > 0)
    end
  end

  context "with an unresolvable plugin" do
    before do
      File.write(".rigor.yml", <<~YAML)
        paths: [.]
        plugins:
          - rigor-this-plugin-does-not-exist
      YAML
    end

    it "reports the load error but exits 0 by default" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("[ERR]")
      expect(out).to include("rigor-this-plugin-does-not-exist")
      expect(out).to include("load error:")
    end

    it "exits 1 under --strict" do
      status, = run(["--strict"])
      expect(status).to eq(1)
    end

    it "marks the row as load_error in JSON" do
      _, out, = run(["--format", "json"])
      parsed = JSON.parse(out)
      plugin = parsed["plugins"].first
      expect(plugin["status"]).to eq("load_error")
      expect(plugin["load_error"]).to include("rigor-this-plugin-does-not-exist")
    end
  end

  context "with mixed loaded + load-error entries" do
    before do
      File.write(".rigor.yml", <<~YAML)
        paths: [.]
        plugins:
          - gem: rigor-activesupport-core-ext
            id: activesupport-core-ext
          - rigor-not-a-real-plugin
      YAML
    end

    it "surfaces both rows and exits 1 only under --strict" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("loaded: 1")
      expect(out).to include("load-error: 1")

      strict_status, = run(["--strict"])
      expect(strict_status).to eq(1)
    end
  end

  context "with an open_receiver-bearing plugin" do
    before do
      # Activate rigor-activerecord, which declares
      # open_receivers: ["ActiveRecord::Relation"]. We don't need
      # a real db/schema.rb because plugin LOADING (manifest
      # resolution + init) does not require the schema — only the
      # later analysis pipeline does, and we never run that here.
      File.write(".rigor.yml", <<~YAML)
        paths: [.]
        plugins:
          - gem: rigor-activerecord
            id: activerecord
      YAML
    end

    it "surfaces open_receivers in the text output" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("open_receivers: ActiveRecord::Relation")
    end

    it "surfaces open_receivers in the JSON output" do
      _, out, = run(["--format", "json"])
      parsed = JSON.parse(out)
      plugin = parsed["plugins"].first
      expect(plugin["open_receivers"]).to include("ActiveRecord::Relation")
    end
  end

  it "rejects an unsupported --format" do
    File.write(".rigor.yml", "paths: [.]\nplugins: []\n")
    expect { run(["--format", "xml"]) }.to raise_error(OptionParser::InvalidArgument)
  end
end
