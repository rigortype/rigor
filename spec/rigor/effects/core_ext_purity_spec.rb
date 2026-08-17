# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/effects_command"

# ADR-103 WD10 / issue #388 — the end-to-end claim the `%a{pure}` sweep over
# `plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs` exists to make true: with the
# effects opt-in on and the plugin enabled through a real `.rigor.yml`, a project method that calls only
# annotated core_ext selectors reads exhaustive with an empty effect list from the real `rigor effects
# --format json` CLI surface — no `%a{rigor:v1:effect}`, no project-side envelope, nothing but the
# accepted-signature lane WD6 / WD7 describe. The per-method RBS audit itself is
# `spec/integration/plugins/activesupport_core_ext_effects_spec.rb`.
RSpec.describe "the ActiveSupport core_ext %a{pure} sweep, end to end" do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI::EffectsCommand.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  # Mirrors `spec/rigor/cli/plugins_command_spec.rb`: `require` is idempotent, so another spec's
  # `Rigor::Plugin.unregister!` can leave the registry empty without this file re-running the gem's
  # top-level `Rigor::Plugin.register(...)` call. Re-register explicitly so this spec is order-independent.
  before do
    require "rigor-activesupport-core-ext"
    Rigor::Plugin.register(Rigor::Plugin::ActivesupportCoreExt) unless
      Rigor::Plugin.registered_for("activesupport-core-ext")

    File.write(".rigor.yml", <<~YAML)
      paths: [.]
      effects: {}
      plugins:
        - gem: rigor-activesupport-core-ext
          id: activesupport-core-ext
    YAML

    # Every call here resolves to a declared RBS type end to end (a String literal, never a bare
    # parameter) so the summary has no `dynamic-receiver` taint to explain — the point under test is
    # purity, not resolution.
    File.write("greeting.rb", <<~RUBY)
      class Greeting
        def pure_chain
          "  hello world  ".squish.titleize.presence
        end
      end
    RUBY
  end

  after { Rigor::Plugin.unregister! }

  it "reads Greeting#pure_chain as exhaustive with no effects, in the default report" do
    status, out, = run(["--full"])

    expect(status).to eq(0)
    expect(out).to include("Greeting#pure_chain: []\n")
  end

  it "reads Greeting#pure_chain as exhaustive-∅ under --format json" do
    status, out, = run(["--format", "json", "--full"])
    payload = JSON.parse(out)

    expect(status).to eq(0)
    entry = payload.dig("methods", "Greeting#pure_chain")
    expect(entry).not_to be_nil, "expected a Greeting#pure_chain entry in #{payload['methods'].keys}"
    expect(entry["effects"]).to eq([])
    expect(entry["exhaustive"]).to be(true)
    expect(entry["causes"]).to eq([])
  end

  it "is omitted from the default (non---full) report — the omission rule for a pure, exhaustive method" do
    _, out, = run(["--format", "json"])
    payload = JSON.parse(out)

    expect(payload.dig("methods", "Greeting#pure_chain")).to be_nil
  end
end
