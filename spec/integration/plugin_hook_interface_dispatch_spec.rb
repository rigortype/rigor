# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

# ADR-130's acceptance in a plugin hook, against this repository's own `sig/` (`sig/rigor/plugin/interfaces.rbs` and
# `base.rbs`): the hook's `scope` is `Dynamic[Rigor::Plugin::_Scope]`, a member `_Scope` declares types its call, one it
# does not declare is silent, and a nilable result reports `call.possible-nil-receiver` as on a `Rigor::Scope`.
RSpec.describe "ADR-130 plugin-interface dispatch in a plugin hook" do
  let(:sig_root) { File.expand_path("../../sig", __dir__) }

  let(:source) do
    <<~RUBY
      class HookProbe < Rigor::Plugin::Base
        node_rule(Prism::CallNode) do |node, scope, _path, _file_context, _context|
          Rigor.dump_type(scope)
          Rigor.dump_type(scope.type_of(node))
          Rigor.dump_type(t_probe)
          Rigor.dump_type(scope.environment)
          Rigor.dump_type(scope.not_declared)
          local = scope.local(:x)
          local.describe
          nil
        end

        def self.t_probe = nil
      end
    RUBY
  end

  let(:probe_sig) do
    <<~RBS
      class HookProbe < Rigor::Plugin::Base
        def self.t_probe: () -> Rigor::Type::t
      end
    RBS
  end

  def run_check(dispatch: true)
    Dir.mktmpdir("rigor-hook-probe") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "lib/hook_probe.rb"), source)
      File.write(File.join(dir, "sig/hook_probe.rbs"), probe_sig)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => [sig_root, "sig"],
                                             "parallel" => { "workers" => 0 })
      )
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, workers: 0)
      run = -> { Dir.chdir(dir) { guarded_run(runner) } }
      result = dispatch ? run.call : Rigor::Inference::MethodDispatcher::RbsDispatch.without_interface_dispatch(&run)
      result.to_h.fetch("diagnostics").to_h do |row|
        [row.fetch("line"), "#{row.fetch('rule')}: #{row.fetch('message')}"]
      end
    end
  end

  it "types the hook's scope and its declared members" do
    rows = run_check

    expect(rows.fetch(3)).to eq("dump.type: dump_type: Dynamic[Rigor::Plugin::_Scope]")
    expect(rows.fetch(5)).to start_with("dump.type: dump_type: Rigor::Type::App | ")
    expect(rows.fetch(4)).to eq(rows.fetch(5))
    expect(rows.fetch(6)).to eq("dump.type: dump_type: Dynamic[Rigor::Plugin::_Environment]")
    expect(rows.fetch(7)).to eq("dump.type: dump_type: Dynamic[top]")
    expect(rows.fetch(9)).to start_with("call.possible-nil-receiver: ")
  end

  it "reads every member as untyped with dispatch off" do
    rows = run_check(dispatch: false)

    expect(rows.fetch(4)).to eq("dump.type: dump_type: Dynamic[top]")
    expect(rows.fetch(6)).to eq("dump.type: dump_type: Dynamic[top]")
    expect(rows).not_to have_key(9)
  end
end
