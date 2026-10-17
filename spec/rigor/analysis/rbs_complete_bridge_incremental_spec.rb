# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #1572 — the ADR-43 bridge withholds when a project entry ahead of the allow-listed ancestor holds the name, read
# through the project-wide def tables, so its answer depends on files other than the call's. Removing `M`'s `def` in
# `a.rb` makes Ruby call `Base#contract_value` (an Integer, so `.upcase` raises), and adding it back makes it `M`'s
# String again. The warm run must re-check `b.rb` each time. The oracle is a full `--no-cache` run of the same tree; the
# driver is `IncrementalSession`, as in `unsettled_chain_incremental_spec.rb`.
RSpec.describe "the RBS-complete bridge's cross-file shadow read — incremental (#1572)" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [File.join(dir, "lib")],
                             "signature_paths" => [File.join(dir, "sig")])
  end

  def shared_environment(dir)
    (@shared_environment ||= Rigor::Environment.for_project(root: dir, signature_paths: [File.join(dir, "sig")]))
  end

  def diagnostics(list)
    list.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment(dir))
    diagnostics(guarded_run(runner).diagnostics)
  end

  let(:with_def) { "module M\n  def contract_value = \"m\"\nend\nmodule A\n  include M\nend\n" }
  let(:without_def) { "module M\nend\nmodule A\n  include M\nend\n" }

  it "re-checks the consumer when the module's def is removed and added back in another file" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "base.rbs"),
                 "module Rigor\n  module Plugin\n    class Base\n      def contract_value: () -> Integer\n    " \
                 "end\n  end\nend\n")
      File.write(File.join(dir, "lib", "a.rb"), with_def)
      File.write(File.join(dir, "lib", "b.rb"),
                 "class Demo < Rigor::Plugin::Base\n  include A\n  def go = contract_value.upcase\nend\n")
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir),
                                                        paths: [File.join(dir, "lib")],
                                                        environment: shared_environment(dir))
      expect(diagnostics(guarded_baseline(session))).to eq([])

      File.write(File.join(dir, "lib", "a.rb"), without_def)
      warm = diagnostics(guarded_recheck(session).diagnostics)
      expect(full_run(dir)).to eq([["b.rb", 3]])
      expect(warm).to eq([["b.rb", 3]])

      File.write(File.join(dir, "lib", "a.rb"), with_def)
      warm = diagnostics(guarded_recheck(session).diagnostics)
      expect(full_run(dir)).to eq([])
      expect(warm).to eq([])
    end
  end
end
