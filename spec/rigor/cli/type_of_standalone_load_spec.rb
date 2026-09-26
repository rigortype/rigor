# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# `rigor type-of` builds its scope without loading `rigor/analysis/check_rules`, so an engine file that names a
# check-rules helper has to require it itself. The in-process suite always has every file loaded and cannot see a
# missing require; this runs the CLI in a child process, as a user does.
RSpec.describe "rigor type-of in a fresh process" do
  let(:exe) { File.join(File.expand_path("../../..", __dir__), "exe", "rigor") }

  it "types a local that was written, without a missing-constant crash" do
    Dir.mktmpdir("rigor-type-of-load-spec-") do |dir|
      File.write(File.join(dir, "probe.rb"), "x = 1\nx\n")
      stdout, stderr, status = Open3.capture3("bundle", "exec", "ruby", exe, "type-of", "probe.rb:2:1", chdir: dir)

      expect(stderr).not_to include("NameError")
      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("1")
    end
  end
end
