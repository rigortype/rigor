# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Issue #2121 — the spec-only `RbsEnvMemo` (spec/support/rbs_env_memo.rb) may hand one example's environment to
# another only when the build would be the same, and a build names each project signature buffer by its absolute
# path. Two projects holding byte-identical `sig/box.rbs` under different roots must not share one.
RSpec.describe RbsEnvMemo do
  def digest_in(dir)
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "sig", "box.rbs"), "class Box\nend\n")
    Dir.chdir(dir) { described_class.digest([], ["sig"], []) }
  end

  it "keys a relative signature root on the absolute path of each file" do
    Dir.mktmpdir("rbs-env-memo-a-") do |first|
      Dir.mktmpdir("rbs-env-memo-b-") do |second|
        expect(digest_in(first)).not_to eq(digest_in(second))
      end
    end
  end
end
