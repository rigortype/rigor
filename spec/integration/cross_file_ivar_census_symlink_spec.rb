# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

# Issue #2079 review m1 — the census skips the analysed file's own `:own_write_type` entries by path. Run from the
# real directory with the target spelled through a symlink, the pre-pass and the analysis name the file differently;
# compared as spelled, the file's own non-literal write joined back as `Dynamic[top]` and silenced the read. Ruby
# 4.0.5 raises NoMethodError on `K.new.get` (`Integer#upcase`).
RSpec.describe "cross-file ivar census under a symlinked spelling (#2079)", type: :runner do
  it "does not join the analysed file's own writes back" do
    Dir.mktmpdir do |dir|
      real = File.join(File.realpath(dir), "proj")
      FileUtils.mkdir_p(File.join(real, "lib"))
      File.write(File.join(real, "lib", "k.rb"),
                 "class K\n  def initialize = (@x = Integer.sqrt(4))\n  def get = @x.upcase\nend\n")
      link = File.join(File.realpath(dir), "alias")
      File.symlink(real, link)
      Dir.chdir(real) do
        configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => ["lib"]))
        runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
        diagnostics = guarded_run(runner, [File.join(link, "lib")]).diagnostics
        rows = diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }
        expect(rows).to eq([["k.rb", 3]])
      end
    end
  end
end
