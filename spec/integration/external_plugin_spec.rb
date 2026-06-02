# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

# v0.2.0 gate-1 evidence (ROADMAP § "v0.2.0 — first evaluation release"):
# a plugin that lives OUTSIDE the monorepo — a third-party `rigor-*` gem
# in its own repo per ADR-31 WD4 — loads via the REAL `require`
# mechanism and runs end-to-end through `Analysis::Runner`, depending
# only on the public plugin contract.
#
# Unlike the bundled-plugin integration specs (which stub the loader's
# `requirer` to register the class directly), this spec drives the
# Runner with no `plugin_requirer`, so the loader uses its real
# `->(name) { require name }` and the genuine gem-load path is
# exercised. Break what an external author can depend on (the ADR-2
# surface, `node_rule`, `#diagnostic`, ADR-40 `config_schema` defaults,
# `Source::Literals`) and this fails.
EXTERNAL_PLUGIN_LIB = File.expand_path(
  "../fixtures/external_plugin/rigor-external-demo/lib", __dir__
)

RSpec.describe "external (out-of-tree) plugin contract" do
  before do
    $LOAD_PATH.unshift(EXTERNAL_PLUGIN_LIB) unless $LOAD_PATH.include?(EXTERNAL_PLUGIN_LIB)
    Rigor::Plugin.unregister!
  end

  after { Rigor::Plugin.unregister! }

  it "loads via real require and runs end-to-end against the public contract" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), <<~RUBY)
        legacy_call(:soon_gone)
        modern_call(:keep)
      RUBY

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "plugins" => [{ "gem" => "rigor-external-demo" }]
        )
      )

      result = Dir.chdir(dir) do
        # No `plugin_requirer:` — the loader falls back to the real
        # `require`, so this loads the fixture gem from $LOAD_PATH for
        # real rather than via a test stub.
        Rigor::Analysis::Runner.new(configuration: configuration).run
      end

      # The plugin registered and produced its diagnostic: proof the
      # out-of-tree gem loaded and ran.
      diagnostics = result.diagnostics.select { |d| d.source_family == "plugin.external-demo" }
      expect(diagnostics.map(&:rule)).to eq(["flagged-call"])

      # ADR-40 default (`flagged_method` → "legacy_call") drove the match
      # without any user config, and `Source::Literals.symbol` named the
      # literal argument — both public surfaces exercised through the
      # real load.
      diagnostic = diagnostics.first
      expect(diagnostic.message).to include("`legacy_call`")
      expect(diagnostic.message).to include(":soon_gone")
      expect(diagnostic.severity).to eq(:warning)
    end
  end
end
