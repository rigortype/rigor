# frozen_string_literal: true

# Issue #1101, follow-up — the END-TO-END half of the composite tier's plugin-typed-record deferral.
#
# `Scope#plugin_typed_calls` (#653) is set-only, and `CheckRules#call_site_exempt?` reads it as an
# exemption from `call.undefined-method` — ahead of the receiver-shape branch, so it covers
# `union_undefined_method_diagnostic` too. The composite tier re-enters `MethodDispatcher#resolve` once
# per projected member, so without the deferral a member a PLUGIN answers, beside a member that
# declines, marks the node plugin-typed for a call the tier went on to decline. The record outlives the
# answer that produced it and silences a real firing.
#
# Two ingredients make it reachable, and both are load-bearing here:
#
# - the receiver must be a NON-NIL, multi-class union (`Ledger | Invoice`), because the union rule
#   defers nil-bearing unions and single-class joins outright; and
# - every arm must be a CLOSED receiver, i.e. RBS declares the class, because
#   `union_arm_blocks_undefined_fire?` bails on an ADR-26 open receiver. A project class with no `sig/`
#   is open, which is why a fixture without this `sig/` reads silent on every arm and proves nothing.
#
# Measured on three builds of this file: tier absent (master) fires, deferral reverted is SILENT, the
# shipped deferral fires again. The spec cannot toggle the dispatcher from inside RSpec, so the middle
# arm is what the assertions below are written to catch — an example that goes red is the record
# outliving its answer.
#
# **What the restored diagnostic is, and what it is not.** The plugin DOES declare `Ledger#settle`, and
# the scalar `solo.settle` is exempt for exactly that reason (#653). The union rule reaches the opposite
# verdict by a path that never asks the registry: `method_present_anywhere?` reads RBS and project
# source only. So the firing this file pins is arguably itself a false positive, and closing that is
# #653's union coverage. It is pre-existing — the same asymmetry holds on master, where this tier does
# not run — and it is NOT what the deferral decides. The deferral decides that a record must not
# outlive the answer that produced it; a stuck record silences whatever the rule would have said,
# including a genuine miss on a union where the plugin answered an unrelated arm.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a composite receiver, a plugin-answered arm, and call.undefined-method (#1101)" do
  # Gated on `Ledger` alone, so exactly one arm of the union below is plugin-answered and the other
  # declines — the shape that leaves the tier with nothing to answer and a record to not leave behind.
  let(:plugin_class) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "unionsink", version: "0.1.0")

      dynamic_return receivers: ["Ledger"], methods: [:settle] do |_call_node, _scope|
        Rigor::Type::Combinator.nominal_of("Receipt")
      end
    end
    stub_const("FakeUnionSinkPlugin", klass)
    klass
  end

  # Declares both classes and neither `#settle`: closed receivers (so the union rule will speak) that
  # genuinely lack the method (so what it says is a miss).
  let(:partial_rbs) do
    <<~RBS
      class Ledger
        def balance: () -> Integer
      end

      class Invoice
        def balance: () -> Integer
      end
    RBS
  end

  let(:source) do
    <<~RUBY
      class Probe
        def run(flag)
          pair = flag ? Ledger.new : Invoice.new
          pair.settle

          solo = Ledger.new
          solo.settle
        end
      end
    RUBY
  end

  def run_analysis(plugins:)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "ledger.rbs"), partial_rbs)
      File.write(File.join(dir, "demo.rb"), source)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "signature_paths" => [File.join(dir, "sig")],
          "plugins" => plugins
        )
      )
      klass = plugin_class
      Dir.chdir(dir) do
        guarded_run(
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda do |_name|
              Rigor::Plugin.register(klass)
              true
            end
          )
        )
      end
    end
  end

  def undefined_lines(result)
    result.diagnostics
          .select { |d| d.qualified_rule == "call.undefined-method" }
          .map { |d| [d.line, d.message] }
  end

  it "keeps reporting the union miss although a plugin answered one arm" do
    # Line 4 is `pair.settle` on `Invoice | Ledger`. The plugin answers the `Ledger` arm; the `Invoice`
    # arm declines, so the composite tier declines and the site's type is NOT the plugin's. Without the
    # deferral the buffered record was committed anyway and this diagnostic disappeared.
    lines = undefined_lines(run_analysis(plugins: ["rigor-unionsink"]))

    expect(lines).to include([4, "undefined method `settle' for Invoice | Ledger"])
  end

  it "CONTROL: the scalar call on the plugin-answered class stays exempt (#653)" do
    # Line 7 is `solo.settle` on a bare `Ledger`, which the plugin DOES answer — so #653's exemption
    # applies and the rule must stay silent. This is what proves the plugin fired at all: a fixture
    # where it never ran would also produce the firing above, for the wrong reason.
    lines = undefined_lines(run_analysis(plugins: ["rigor-unionsink"]))

    expect(lines.map(&:first)).not_to include(7)
  end

  it "CONTROL: without the plugin both calls are misses, so the rule can speak on this fixture" do
    # Discriminates both examples above: it shows the union rule and the scalar rule each reach this
    # source, so the silence at line 7 is the exemption working and not a fixture the rules never see.
    lines = undefined_lines(run_analysis(plugins: []))

    expect(lines).to include([4, "undefined method `settle' for Invoice | Ledger"])
    expect(lines).to include([7, "undefined method `settle' for Ledger"])
  end
end
