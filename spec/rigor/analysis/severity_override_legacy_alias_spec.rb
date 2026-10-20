# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/analysis/runner"

# #2005 — a legacy unprefixed alias (`undefined-method`) used as a `severity_overrides:` key reaches no row: the
# severity resolver matches canonical ids only, and the override map is not alias-normalised. The key stays inert, so
# the row keeps its authored severity, and ConfigAudit names the canonical id (config_audit_spec.rb). Honouring the
# alias is a user-visible change and waits for the maintainer (approval-queue.d).
RSpec.describe "severity_overrides: a legacy alias key (#2005)" do
  let(:source) { "x = 1\nx.nosuchmethod\n" }

  # `{ rule => severity }` of the kept rows for `a.rb` checked under `overrides`, in-process or under `workers:`.
  def rows_for(overrides, workers: nil)
    Dir.mktmpdir("rigor-2005-") do |dir|
      Dir.chdir(dir) do
        File.write("a.rb", source)
        config = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => ["a.rb"], "severity_overrides" => overrides)
        )
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil,
                                             **(workers ? { workers: workers } : {}))
        guarded_run(runner).diagnostics.to_h { [it.rule, it.severity] }
      end
    end
  end

  [nil, 2].each do |workers|
    label = workers ? "under --workers #{workers}" : "in-process"

    it "keeps the canonical row at its authored severity when the key is a legacy alias (#{label})" do
      rows = rows_for({ "undefined-method" => "off" }, workers: workers)

      expect(rows.fetch("call.undefined-method")).to eq(:error)
    end

    it "drops the row when the key is the canonical id, so the alias case is the one that is inert (#{label})" do
      rows = rows_for({ "call.undefined-method" => "off" }, workers: workers)

      expect(rows).not_to have_key("call.undefined-method")
    end
  end
end
