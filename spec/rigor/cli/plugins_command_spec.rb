# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/plugins_command"

# `rigor plugins` is a read-only inspection command that loads the project's `.rigor.yml`, attempts plugin activation,
# and reports per-plugin status (loaded / load-error) plus every manifest-declared extension surface.
#
# The integration-style examples here exercise the real `Plugin::Loader` rather than mocking the registry — that is the
# contract the SKILL / `rigor init` / CI consumers actually depend on.
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

  # Other plugin integration specs in the suite call `Rigor::Plugin.unregister!` in their before/after hooks, which can
  # leave the global registry empty when our spec runs after them. Since `require` is a no-op for an already-loaded
  # plugin file, the file's top-level `Rigor::Plugin.register(...)` call does NOT re-run; the loader then can't match
  # the gem name to a registered class. Re-register the plugins our examples reference so the spec is order-independent.
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

  # ADR-93 WD2 — with no `plugins:` entry, `Configuration.load` auto-wires the bundled `rigor-rbs-inline`
  # plugin when the upstream library is resolvable, so `rigor plugins` reports the plugin set that analysis
  # actually loads. Tagged `:rbs_inline_autowire` so the suite-wide probe pin (spec_helper) is lifted; the
  # plugin is re-registered here because the shared before-hooks that clear the registry leave `require` a
  # no-op (see the comment on the top-level before).
  context "with rigor-rbs-inline auto-wired (ADR-93 WD2)", :rbs_inline_autowire do
    before do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(true)
      require "rigor-rbs-inline"
      Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")
      File.write(".rigor.yml", "paths: [.]\nplugins: []\n")
    end

    it "reports the auto-wired plugin as loaded even with no plugins: entry" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("loaded: 1")
      expect(out).to include("rbs-inline")
    end

    it "does not auto-wire when the user opts out with enabled: false" do
      File.write(".rigor.yml", "paths: [.]\nplugins:\n  - gem: rigor-rbs-inline\n    enabled: false\n")
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("loaded: 0")
    end
  end

  context "with a valid bundled plugin" do
    before do
      # Use the explicit gem/id form so the loader's id-based lookup matches the already-registered plugin class even
      # when the require is a no-op (the plugin gets eager-loaded by other specs in the suite; `require` is idempotent
      # which makes the loader's bare-string newly_registered detector miss).
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

  # ADR-90 — activation-time inflection probe: a loaded `Plugin::Inflector` consumer triggers a real
  # `available?` probe so a standalone install where inflection-dependent checks silently degrade reports the
  # degradation instead of an unqualified `[OK]`.
  context "with an Inflector-consuming plugin loaded (ADR-90)" do
    before do
      File.write(".rigor.yml", <<~YAML)
        paths: [.]
        plugins:
          - gem: rigor-activerecord
            id: activerecord
      YAML
    end

    it "reports the probe result in JSON" do
      _, out, = run(["--format", "json"])
      parsed = JSON.parse(out)
      expect(parsed["inflection"]).to include("required_by" => ["activerecord"])
      expect(parsed["inflection"]).to have_key("available")
    end

    it "prints no warning when inflection is available" do
      allow(Rigor::Plugin::Inflector).to receive(:available?).and_return(true)
      _, out, = run([])
      expect(out).not_to include("WARNING: ActiveSupport::Inflector")
    end

    it "warns in the text view when inflection is unavailable" do
      allow(Rigor::Plugin::Inflector).to receive(:available?).and_return(false)
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("WARNING: ActiveSupport::Inflector is not loadable")
      expect(out).to include("activerecord")
      expect(out).to include("bundle install")
    end

    it "marks the degradation in JSON when inflection is unavailable" do
      allow(Rigor::Plugin::Inflector).to receive(:available?).and_return(false)
      _, out, = run(["--format", "json"])
      parsed = JSON.parse(out)
      expect(parsed["inflection"]).to eq({ "required_by" => ["activerecord"], "available" => false })
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
      # Activate rigor-activerecord, which declares open_receivers: ["ActiveRecord::Relation"]. We don't need a real
      # db/schema.rb because plugin LOADING (manifest resolution + init) does not require the schema — only the later
      # analysis pipeline does, and we never run that here.
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

  context "with --capabilities (ADR-37 extension-protocol catalogue)" do
    before do
      require "rigor-actionpack"
      Rigor::Plugin.register(Rigor::Plugin::Actionpack) unless Rigor::Plugin.registered_for("actionpack")
      File.write(".rigor.yml", <<~YAML)
        paths: [.]
        plugins:
          - gem: rigor-actionpack
            id: actionpack
      YAML
    end

    it "lists the plugin's node_rule node types and consumed facts in text" do
      status, out, = run(["--capabilities"])
      expect(status).to eq(0)
      expect(out).to include("Plugin capability catalogue")
      expect(out).to include("node_rule: Prism::CallNode")
      # Each Prism::CallNode rule is listed once, not per-rule.
      expect(out.scan("Prism::CallNode").size).to eq(1)
      expect(out).to include("consumes:")
    end

    it "emits a focused capability object in JSON" do
      status, out, = run(["--capabilities", "--format", "json"])
      expect(status).to eq(0)
      parsed = JSON.parse(out)
      expect(parsed.keys).to contain_exactly("configuration", "capabilities")
      plugin = parsed["capabilities"].first
      expect(plugin.keys).to contain_exactly(
        "id", "gem", "version", "node_rule_types",
        "dynamic_return_receivers", "narrowing_facts_methods", "produces", "consumes"
      )
      expect(plugin["node_rule_types"]).to eq(["Prism::CallNode"])
    end

    it "also surfaces the narrow protocols in the full report" do
      _, out, = run(["--format", "json"])
      plugin = JSON.parse(out)["plugins"].first
      expect(plugin["node_rule_types"]).to eq(["Prism::CallNode"])
    end
  end

  it "rejects an unsupported --format" do
    File.write(".rigor.yml", "paths: [.]\nplugins: []\n")
    expect { run(["--format", "xml"]) }.to raise_error(OptionParser::InvalidArgument)
  end
end
