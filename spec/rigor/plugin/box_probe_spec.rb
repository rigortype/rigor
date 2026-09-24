# frozen_string_literal: true

require "spec_helper"
require "rigor/plugin/box_probe"
require "open3"
require "tmpdir"

# The launcher's pre-exec check that the running Ruby can host Rigor under `RUBY_BOX=1` (Ruby Bug #22260). The
# classification examples drive the real spawn + pipe path through stand-in `ruby` executables, so each verdict is
# reached the way the launcher reaches it; the last group runs the probe against the Ruby running this suite.
released_without_fix = RUBY_PATCHLEVEL >= 0 &&
                       Gem::Version.new(RUBY_VERSION).between?(Gem::Version.new("4.0.0"), Gem::Version.new("4.0.7"))

RSpec.describe Rigor::Plugin::BoxProbe do
  def fake_ruby(dir, body)
    path = File.join(dir, "ruby")
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  describe ".unsupported_reason" do
    it "passes a Ruby whose child prints the reproducer's correct answer" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "printf '(3/4)'"))).to be_nil
      end
    end

    it "names the missing feature when the child reports Ruby::Box inactive" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "exit 2")))
          .to include("Ruby::Box is not available")
      end
    end

    it "names Bug #22260 when the child dies on a signal" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "kill -SEGV $$")))
          .to include("Ruby Bug #22260")
      end
    end

    it "refuses a child that exits cleanly with the wrong answer" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(fake_ruby(dir, "printf '(1/2)'"))).to include("Ruby Bug #22260")
      end
    end

    it "refuses when the Ruby cannot be started at all" do
      Dir.mktmpdir do |dir|
        expect(described_class.unsupported_reason(File.join(dir, "no-such-ruby"))).to include("could not start")
      end
    end
  end

  describe "against the Ruby running this suite" do
    it "treats Ruby::Box as absent when the child is started without RUBY_BOX" do
      output, status = Open3.capture2e({ "RUBY_BOX" => nil }, RbConfig.ruby, "--disable-gems",
                                       "-e", described_class::SCRIPT)
      expect([output, status.exitstatus]).to eq(["", 2])
    end

    it "rejects every released Ruby 4.0 through 4.0.7, which crashes on Bug #22260",
       if: released_without_fix do
      expect(described_class.unsupported_reason).to include("Ruby Bug #22260")
    end
  end
end
